import 'dart:convert';

import 'package:aureus_ai/models/pivot.dart';
import 'package:aureus_ai/models/trade_setup.dart';
import 'package:aureus_ai/services/emergency_service.dart';
import 'package:aureus_ai/services/history_store.dart';
import 'package:aureus_ai/services/mt5_trading_service.dart';
import 'package:aureus_ai/services/signal_checker.dart';
import 'package:aureus_ai/services/strategy_config_service.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

TradeSetup _trade({int? ticket, DateTime? at, TradeOutcome outcome = TradeOutcome.open}) => TradeSetup(
      symbol: 'XAUUSD',
      direction: TradeDirection.buy,
      timeframeLabel: '15M',
      setupType: SetupType.rangingBounce,
      entry: 2400,
      stopLoss: 2390,
      takeProfit: 2418,
      pattern: CandlePattern.bullishPinbar,
      detectedAt: at ?? DateTime.utc(2026, 10, 2, 10),
      brokerTicket: ticket,
      outcome: outcome,
    );

Future<void> _seed(List<TradeSetup> trades) => HistoryStore.mutate((h) {
      h.insertAll(0, trades);
      return true;
    });

Future<TradeSetup> _stored(TradeSetup like) async => (await HistoryStore.load()).firstWhere((s) => s.uid == like.uid);

http.Response _json(Object body, [int status = 200]) => http.Response(jsonEncode(body), status);

void main() {
  late List<http.Request> requests;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    StrategyConfig.instance.resetForTesting();
    dotenv.testLoad(
      fileInput:
          'USE_MOCK_DATA=false\nDISABLE_MT5_BRIDGE=false\nBRIDGE_BASE_URL=http://bridge.test\nMT5_SYMBOL=XAUUSD...',
    );
    requests = [];
  });
  tearDown(() => StrategyConfig.instance.resetForTesting());

  SignalChecker checkerWith(http.Response Function(http.Request) handler) => SignalChecker(
        trading: Mt5TradingService(client: MockClient((request) async {
          requests.add(request);
          return handler(request);
        })),
      );

  group('manual close of a real MT5 position', () {
    test('closes on the broker first, then records the broker\'s fill price', () async {
      final trade = _trade(ticket: 777);
      await _seed([trade]);
      final checker = checkerWith((_) => _json({'success': true, 'price': 2412.3}));

      final result = await checker.closeTradeManually(trade.uid, 2400.0);

      expect(result.closed, isTrue);
      expect(result.brokerClosed, isTrue);
      expect(result.message, contains('2412.30'));
      expect(requests.single.url.path, '/order/close');
      expect(jsonDecode(requests.single.body), {'ticket': 777});
      final stored = await _stored(trade);
      expect(stored.outcome, TradeOutcome.manualClose);
      expect(stored.closedPrice, 2412.3);
    });

    test('a broker rejection leaves the trade OPEN and says why', () async {
      final trade = _trade(ticket: 777);
      await _seed([trade]);
      final checker = checkerWith((_) => _json({'success': false, 'error': 'retcode 10018: Market closed'}));

      final result = await checker.closeTradeManually(trade.uid, 2400.0);

      expect(result.closed, isFalse);
      expect(result.message, contains('Market closed'));
      expect(result.message, contains('still open'));
      expect((await _stored(trade)).outcome, TradeOutcome.open);
    });

    test('an unreachable bridge leaves the trade open too', () async {
      final trade = _trade(ticket: 777);
      await _seed([trade]);
      final checker = SignalChecker(
        trading: Mt5TradingService(client: MockClient((_) async => throw Exception('connection refused'))),
      );
      final result = await checker.closeTradeManually(trade.uid, 2400.0);
      expect(result.closed, isFalse);
      expect((await _stored(trade)).outcome, TradeOutcome.open);
    });

    test('mock / bridge-disabled mode never pretends to close a real position', () async {
      dotenv.testLoad(fileInput: 'USE_MOCK_DATA=true');
      final trade = _trade(ticket: 777);
      await _seed([trade]);
      final result =
          await checkerWith((_) => _json({'success': true, 'price': 1})).closeTradeManually(trade.uid, 2400.0);
      expect(result.closed, isFalse);
      expect(requests, isEmpty);
      expect((await _stored(trade)).outcome, TradeOutcome.open);
    });

    test('"position not found" means it is already closed at the broker: record it locally', () async {
      final trade = _trade(ticket: 777);
      await _seed([trade]);
      final checker = checkerWith(
        (_) => _json({'success': false, 'not_found': true, 'error': 'Position #777 not found (already closed?)'}),
      );

      final result = await checker.closeTradeManually(trade.uid, 2405.5);

      expect(result.closed, isTrue);
      expect(result.brokerClosed, isFalse);
      expect(result.message, contains('already closed'));
      final stored = await _stored(trade);
      expect(stored.outcome, TradeOutcome.manualClose);
      expect(stored.closedPrice, 2405.5);
    });
  });

  group('manual close of other trades', () {
    test('a signal-only trade is closed locally with no broker call', () async {
      final trade = _trade();
      await _seed([trade]);
      final result = await checkerWith((_) => _json({})).closeTradeManually(trade.uid, 2403.0);
      expect(result.closed, isTrue);
      expect(result.message, contains('signal only'));
      expect(requests, isEmpty);
      expect((await _stored(trade)).closedPrice, 2403.0);
    });

    test('an already-closed or unknown trade is refused, with no broker call', () async {
      final done = _trade(ticket: 5, outcome: TradeOutcome.win);
      await _seed([done]);
      final checker = checkerWith((_) => _json({'success': true, 'price': 1}));
      expect((await checker.closeTradeManually(done.uid, 2400)).closed, isFalse);
      expect((await checker.closeTradeManually('nope', 2400)).message, contains('already closed'));
      expect(requests, isEmpty);
    });
  });

  group('EmergencyService', () {
    final paused = {
      'mode': {'paused': true}
    };
    Map<String, dynamic> configBody(int revision, {bool isPaused = false}) => {
          'revision': revision,
          'config': {
            'updated_by': 'app',
            'mode': {'paused': isPaused, 'auto_trade': 'off'},
          },
          'bounds': <String, dynamic>{},
          'meta': <String, dynamic>{},
        };

    http.Response Function(http.Request) bridge({
      bool alreadyPaused = false,
      int configStatus = 200,
      List<Map<String, dynamic>> closed = const [],
      bool closeAllFails = false,
    }) {
      return (request) {
        switch ('${request.method} ${request.url.path}') {
          case 'GET /config':
            return configStatus == 200
                ? _json(configBody(5, isPaused: alreadyPaused))
                : http.Response('boom', configStatus);
          case 'POST /config/update':
            return _json(configBody(6, isPaused: true));
          case 'POST /order/close_all':
            if (closeAllFails) throw Exception('connection refused');
            return _json({'success': closed.every((c) => c['success'] == true), 'closed': closed});
        }
        return http.Response('not found', 404);
      };
    }

    EmergencyService service(http.Response Function(http.Request) handler) => EmergencyService(
          client: MockClient((request) async {
            requests.add(request);
            return handler(request);
          }),
        );

    test('pauses first, closes every position, and records only the ones that really closed', () async {
      final a = _trade(ticket: 777, at: DateTime.utc(2026, 10, 2, 10));
      final b = _trade(ticket: 888, at: DateTime.utc(2026, 10, 2, 11));
      final c = _trade(at: DateTime.utc(2026, 10, 2, 12));
      await _seed([a, b, c]);

      final result = await service(bridge(closed: [
        {'ticket': 777, 'success': true, 'price': 2410.5},
        {'ticket': 888, 'success': false, 'error': 'Market closed'},
      ])).closeAllAndPause();

      expect(
          requests.map((r) => '${r.method} ${r.url.path}').toList(),
          [
            'GET /config',
            'POST /config/update',
            'POST /order/close_all',
          ],
          reason: 'pause must come before closing');
      expect(jsonDecode(requests[1].body)['patch'], paused);
      expect(jsonDecode(requests[2].body), {'symbol': 'XAUUSD...'});

      expect(result.paused, isTrue);
      expect(result.closed, 1);
      expect(result.failed, 1);
      expect(result.recordedLocally, 1);
      expect(result.allClear, isFalse);
      expect(result.summary, contains('STILL OPEN'));
      expect(result.problems.single, contains('#888'));

      expect((await _stored(a)).outcome, TradeOutcome.manualClose);
      expect((await _stored(a)).closedPrice, 2410.5);
      expect((await _stored(b)).outcome, TradeOutcome.open, reason: 'the broker did not close it');
      expect((await _stored(c)).outcome, TradeOutcome.open, reason: 'signal-only trades are left alone');
    });

    test('an already-paused bridge is not asked to pause again', () async {
      final result = await service(bridge(alreadyPaused: true)).closeAllAndPause();
      expect(requests.where((r) => r.url.path == '/config/update'), isEmpty);
      expect(result.paused, isTrue);
      expect(result.allClear, isTrue);
      expect(result.summary, contains('No open MT5 positions'));
    });

    test('a failed pause never stops the closing, and is reported', () async {
      final a = _trade(ticket: 777);
      await _seed([a]);
      final result = await service(bridge(
        configStatus: 500,
        closed: [
          {'ticket': 777, 'success': true, 'price': 2410.5},
        ],
      )).closeAllAndPause();

      expect(result.paused, isFalse);
      expect(result.closed, 1);
      expect(result.allClear, isFalse);
      expect(result.summary, contains('COULD NOT pause'));
      expect((await _stored(a)).outcome, TradeOutcome.manualClose);
    });

    test('an unreachable close-all is reported, not swallowed', () async {
      final a = _trade(ticket: 777);
      await _seed([a]);
      final result = await service(bridge(alreadyPaused: true, closeAllFails: true)).closeAllAndPause();
      expect(result.allClear, isFalse);
      expect(result.problems.join(' '), contains('Close-all'));
      expect((await _stored(a)).outcome, TradeOutcome.open);
    });
  });
}
