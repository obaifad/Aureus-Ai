import 'dart:convert';

import 'package:aureus_ai/models/pivot.dart';
import 'package:aureus_ai/models/trade_setup.dart';
import 'package:aureus_ai/services/app_logger.dart';
import 'package:aureus_ai/services/broker_reconciler.dart';
import 'package:aureus_ai/services/history_store.dart';
import 'package:aureus_ai/services/monitor_engine.dart';
import 'package:aureus_ai/services/mt5_trading_service.dart';
import 'package:aureus_ai/services/signal_checker.dart';
import 'package:aureus_ai/services/tick_stream_service.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _now = DateTime.utc(2026, 10, 2, 12);

TradeSetup _trade({
  int? ticket = 777,
  TradeDirection dir = TradeDirection.buy,
  TradeOutcome outcome = TradeOutcome.open,
  double entry = 2400,
  double sl = 2390,
  double tp = 2418,
  double? closedPrice,
  DateTime? closedAt,
  DateTime? at,
}) =>
    TradeSetup(
      symbol: 'XAUUSD',
      direction: dir,
      timeframeLabel: '15M',
      setupType: SetupType.rangingBounce,
      entry: entry,
      stopLoss: sl,
      takeProfit: tp,
      pattern: CandlePattern.bullishPinbar,
      detectedAt: at ?? DateTime.utc(2026, 10, 2, 9),
      brokerTicket: ticket,
      outcome: outcome,
      closedPrice: closedPrice,
      closedAt: closedAt,
    );

Future<void> _seed(List<TradeSetup> trades) => HistoryStore.mutate((h) {
      h.insertAll(0, trades);
      return true;
    });

Future<List<TradeSetup>> _all() => HistoryStore.load();
Future<TradeSetup> _byTicket(int t) async => (await _all()).firstWhere((s) => s.brokerTicket == t);

Map<String, dynamic> _pos(int ticket,
        {String type = 'buy', double open = 2400.2, int magic = 20260920, double sl = 2390, double tp = 2418}) =>
    {
      'ticket': ticket,
      'symbol': 'XAUUSD...',
      'type': type,
      'volume': 0.5,
      'price_open': open,
      'sl': sl,
      'tp': tp,
      'profit': 12.0,
      'magic': magic,
      'time_open': _now.subtract(const Duration(hours: 3)).millisecondsSinceEpoch ~/ 1000,
    };

Map<String, dynamic> _closed(
  int ticket, {
  String type = 'buy',
  double open = 2400.2,
  double close = 2418.4,
  String reason = 'tp',
  double profit = 480.5,
  DateTime? at,
}) =>
    {
      'ticket': ticket,
      'symbol': 'XAUUSD...',
      'type': type,
      'volume': 0.5,
      'price_open': open,
      'price_close': close,
      'time_open': _now.subtract(const Duration(hours: 3)).millisecondsSinceEpoch ~/ 1000,
      'time_close': (at ?? _now.subtract(const Duration(minutes: 5))).millisecondsSinceEpoch ~/ 1000,
      'profit': profit,
      'reason': reason,
      'magic': 20260920,
    };

void main() {
  late List<http.Request> requests;
  late Map<String, dynamic> broker;
  late http.Response Function(http.Request) respond;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    dotenv.testLoad(
      fileInput:
          'USE_MOCK_DATA=false\nDISABLE_MT5_BRIDGE=false\nBRIDGE_BASE_URL=http://bridge.test\nMT5_SYMBOL=XAUUSD...',
    );
    requests = [];
    broker = {'positions': <dynamic>[], 'closed': <dynamic>[], 'history_ok': true};
    respond = (_) => http.Response(jsonEncode(broker), 200);
  });

  Mt5TradingService trading() => Mt5TradingService(client: MockClient((request) async {
        requests.add(request);
        return respond(request);
      }));

  BrokerReconciler reconciler() => BrokerReconciler(trading: trading(), clock: () => _now);

  group('closing from the broker\'s record', () {
    test('an open trade the broker closed takes the broker\'s price, time, profit and reason', () async {
      await _seed([_trade()]);
      broker['closed'] = [_closed(777, close: 2418.4, profit: 480.5)];

      final r = await reconciler().reconcile();

      expect(r.ran, isTrue);
      expect(r.newlyClosed, hasLength(1));
      final s = await _byTicket(777);
      expect(s.outcome, TradeOutcome.win);
      expect(s.closedPrice, 2418.4);
      expect(s.closedAt, _now.subtract(const Duration(minutes: 5)));
      expect(s.brokerProfit, 480.5);
      expect(s.closeReason, 'tp');
      expect(s.actualFillPrice, 2400.2, reason: 'the broker\'s fill is the real entry');
      expect(s.pips, closeTo(182.0, 0.05), reason: 'pips come from the REAL fill and exit');
      expect(requests.single.url.path, '/reconcile');
      expect(requests.single.url.queryParameters['symbol'], 'XAUUSD...');
    });

    test('the close reason decides the outcome', () async {
      final cases = {
        'tp': TradeOutcome.win,
        'sl': TradeOutcome.loss,
        'stop_out': TradeOutcome.loss,
        'manual': TradeOutcome.manualClose,
        'expert': TradeOutcome.manualClose,
        'other': TradeOutcome.manualClose,
      };
      for (final entry in cases.entries) {
        SharedPreferences.setMockInitialValues({});
        await _seed([_trade()]);
        broker['closed'] = [_closed(777, reason: entry.key)];
        await reconciler().reconcile();
        expect((await _byTicket(777)).outcome, entry.value, reason: entry.key);
      }
    });

    test('a sell is measured the right way round', () async {
      await _seed([_trade(dir: TradeDirection.sell, entry: 2400, sl: 2410, tp: 2382)]);
      broker['closed'] = [_closed(777, type: 'sell', open: 2399.8, close: 2381.0, reason: 'tp')];
      await reconciler().reconcile();
      expect((await _byTicket(777)).pips, closeTo(188.0, 0.05));
    });

    test('a trade still open at the broker stays open, and its real fill is recorded', () async {
      await _seed([_trade()]);
      broker['positions'] = [_pos(777, open: 2400.35)];
      final r = await reconciler().reconcile();
      expect(r.stillOpen, 1);
      expect(r.newlyClosed, isEmpty);
      final s = await _byTicket(777);
      expect(s.outcome, TradeOutcome.open);
      expect(s.actualFillPrice, 2400.35);
    });

    test('an open trade the broker knows nothing about is flagged, never guessed', () async {
      await _seed([_trade()]);
      final r = await reconciler().reconcile();
      expect(r.unresolved.single, contains('#777'));
      expect(r.changedAnything, isFalse);
      expect((await _byTicket(777)).outcome, TradeOutcome.open);
    });

    test('unreadable deal history concludes nothing about closes', () async {
      await _seed([_trade()]);
      broker['history_ok'] = false;
      broker['closed'] = [_closed(777)];
      final r = await reconciler().reconcile();
      expect(r.newlyClosed, isEmpty);
      expect((await _byTicket(777)).outcome, TradeOutcome.open);
    });
  });

  group('correcting and reopening', () {
    test('a trade the app closed on an estimate is corrected to the broker\'s real exit — once', () async {
      await _seed([
        _trade(outcome: TradeOutcome.win, closedPrice: 2418.0, closedAt: _now.subtract(const Duration(minutes: 6))),
      ]);
      broker['closed'] = [_closed(777, close: 2419.4, profit: 495.0)];

      final first = await reconciler().reconcile();
      expect(first.corrected, 1);
      final s = await _byTicket(777);
      expect(s.closedPrice, 2419.4);
      expect(s.brokerProfit, 495.0);
      expect(s.outcome, TradeOutcome.win);

      final second = await reconciler().reconcile();
      expect(second.corrected, 0, reason: 'already in sync — a repeat pass changes nothing');
      expect(second.changedAnything, isFalse);
    });

    test('a user\'s manual close keeps its label and gains the broker\'s numbers', () async {
      await _seed([
        _trade(
            outcome: TradeOutcome.manualClose,
            closedPrice: 2410.0,
            closedAt: _now.subtract(const Duration(minutes: 6))),
      ]);
      broker['closed'] = [_closed(777, close: 2410.6, reason: 'manual', profit: 100.0)];
      await reconciler().reconcile();
      final s = await _byTicket(777);
      expect(s.outcome, TradeOutcome.manualClose);
      expect(s.closedPrice, 2410.6);
      expect(s.closeReason, 'manual');
    });

    test('closed in the app but the REAL position is still open: reopened', () async {
      await _seed([
        _trade(outcome: TradeOutcome.loss, closedPrice: 2390.0, closedAt: _now.subtract(const Duration(minutes: 20))),
      ]);
      broker['positions'] = [_pos(777)];
      final r = await reconciler().reconcile();
      expect(r.reopened, 1);
      expect(r.hasWarnings, isTrue);
      final s = await _byTicket(777);
      expect(s.outcome, TradeOutcome.open);
      expect(s.closedPrice, isNull);
      expect(s.closedAt, isNull);
    });

    test('an old mismatch is not treated as a live position', () async {
      await _seed([
        _trade(outcome: TradeOutcome.loss, closedPrice: 2390.0, closedAt: _now.subtract(const Duration(hours: 9))),
      ]);
      broker['positions'] = [_pos(777)];
      expect((await reconciler().reconcile()).reopened, 0);
      expect((await _byTicket(777)).outcome, TradeOutcome.loss);
    });

    test('a manual close is never reopened', () async {
      await _seed([
        _trade(
            outcome: TradeOutcome.manualClose,
            closedPrice: 2405.0,
            closedAt: _now.subtract(const Duration(minutes: 3))),
      ]);
      broker['positions'] = [_pos(777)];
      expect((await reconciler().reconcile()).reopened, 0);
    });
  });

  group('orphans and other people\'s positions', () {
    test('a position of ours that the app never recorded is adopted exactly once', () async {
      broker['positions'] = [_pos(901, type: 'sell', open: 2410.25, sl: 2420, tp: 2392)];
      final first = await reconciler().reconcile();
      expect(first.adopted, 1);
      final s = await _byTicket(901);
      expect(s.outcome, TradeOutcome.open);
      expect(s.direction, TradeDirection.sell);
      expect(s.entry, 2410.25);
      expect(s.stopLoss, 2420);
      expect(s.takeProfit, 2392);
      expect(s.dataSource, 'MT5 (adopted)');
      expect(s.lotSize, 0.5);

      expect((await reconciler().reconcile()).adopted, 0);
      expect((await _all()).where((t) => t.brokerTicket == 901), hasLength(1));
    });

    test('positions opened by hand (other magic number) are left alone and never pollute the history', () async {
      broker['positions'] = [_pos(902, magic: 0)];
      final r = await reconciler().reconcile();
      expect(r.adopted, 0);
      expect(r.foreign, 1);
      expect(await _all(), isEmpty);
    });

    test('signal-only trades are untouched', () async {
      await _seed([_trade(ticket: null)]);
      broker['closed'] = [_closed(777)];
      final r = await reconciler().reconcile();
      expect(r.changedAnything, isFalse);
      expect((await _all()).single.outcome, TradeOutcome.open);
    });
  });

  group('failing safe', () {
    test('an unreachable bridge changes nothing and says so', () async {
      await _seed([_trade()]);
      final r = await BrokerReconciler(
        trading: Mt5TradingService(client: MockClient((_) async => throw Exception('connection refused'))),
        clock: () => _now,
      ).reconcile();
      expect(r.ran, isFalse);
      expect(r.error, isNotNull);
      expect((await _byTicket(777)).outcome, TradeOutcome.open);
    });

    test('a bridge error status changes nothing', () async {
      await _seed([_trade()]);
      respond = (_) => http.Response('{"detail":"no mt5"}', 503);
      expect((await reconciler().reconcile()).ran, isFalse);
    });

    // 2026-10-09: after a restart the bridge refuses /reconcile until a fresh tick confirms the MT5 server-time
    // offset — before that, the app had rewritten 12-14 close times 3 h late. Nothing may change while it waits,
    // and in the gold daily break (up to an hour of scans) the log says so ONCE, not on every scan.
    test('while the bridge has not confirmed the server time, nothing changes and the log says so once', () async {
      final closedEarlier = _trade()
        ..outcome = TradeOutcome.win
        ..closedPrice = 2418.4
        ..closedAt = _now.subtract(const Duration(hours: 2));
      await _seed([closedEarlier]);
      broker['closed'] = [_closed(777, close: 2418.4, profit: 480.5)];
      respond = (_) => http.Response(
          '{"detail":"MT5 server time offset not confirmed yet - waiting for a fresh tick"}', 503);
      final before = AppLogger.entries.where((l) => l.contains('server time')).length;

      for (var i = 0; i < 4; i++) {
        final r = await reconciler().reconcile();
        expect(r.ran, isFalse);
        expect(r.corrected, 0);
      }
      final s = await _byTicket(777);
      expect(s.closedAt, _now.subtract(const Duration(hours: 2)), reason: 'the stored close time is untouched');
      expect(AppLogger.entries.where((l) => l.contains('server time')).length - before, 1);

      // The first fresh tick: the bridge answers again, the log says so, and reconciling resumes.
      respond = (_) => http.Response(jsonEncode(broker), 200);
      expect((await reconciler().reconcile()).ran, isTrue);
      expect(AppLogger.entries.last, contains('/reconcile available again'));
    });

    test('mock mode and RECONCILE_WITH_BROKER=false never touch the network', () async {
      dotenv.testLoad(fileInput: 'USE_MOCK_DATA=true');
      expect((await reconciler().reconcile()).ran, isFalse);
      dotenv.testLoad(
        fileInput:
            'USE_MOCK_DATA=false\nDISABLE_MT5_BRIDGE=false\nRECONCILE_WITH_BROKER=false\nBRIDGE_BASE_URL=http://bridge.test',
      );
      expect((await reconciler().reconcile()).ran, isFalse);
      expect(requests, isEmpty);
    });
  });

  group('the app stops guessing for real positions', () {
    test('the tick sweep leaves a ticketed trade to the broker but still closes a signal-only one', () async {
      final real = _trade(ticket: 777);
      final virtual = _trade(ticket: null, at: DateTime.utc(2026, 10, 2, 9, 1));
      await _seed([real, virtual]);
      final checker = SignalChecker(trading: trading());

      // Price far below both stop losses.
      await checker.resolveOpenTradesAtTick(bid: 2380, ask: 2380.3);

      final stored = await _all();
      expect(stored.firstWhere((s) => s.brokerTicket == 777).outcome, TradeOutcome.open);
      expect(stored.firstWhere((s) => s.brokerTicket == null).outcome, TradeOutcome.loss);
    });

    test('with reconciliation off the old behaviour returns: ticketed trades close on the estimate', () async {
      dotenv.testLoad(fileInput: 'USE_MOCK_DATA=true');
      await _seed([_trade(ticket: 777)]);
      await SignalChecker(trading: trading()).resolveOpenTradesAtTick(bid: 2380, ask: 2380.3);
      expect((await _byTicket(777)).outcome, TradeOutcome.loss);
    });

    test('SignalChecker.reconcile applies the broker record', () async {
      await _seed([_trade()]);
      broker['closed'] = [_closed(777, reason: 'sl', close: 2389.7, profit: -520.0)];
      final r = await SignalChecker(trading: trading()).reconcile();
      expect(r.newlyClosed, hasLength(1));
      expect((await _byTicket(777)).outcome, TradeOutcome.loss);
    });
  });

  group('MonitorEngine tick path', () {
    test('price crossing a real position\'s stop triggers a broker reconcile, not a local close', () async {
      await _seed([_trade()]);
      broker['closed'] = [_closed(777, reason: 'sl', close: 2389.9, profit: -510.0)];
      final events = <Map<String, Object?>>[];
      final engine = MonitorEngine(onEvent: events.add, checker: SignalChecker(trading: trading()));
      await engine.init();

      await engine.handleTickForTest(Tick(time: _now, bid: 2385, ask: 2385.3, last: 2385));
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(requests.where((r) => r.url.path == '/reconcile'), isNotEmpty);
      final s = await _byTicket(777);
      expect(s.outcome, TradeOutcome.loss);
      expect(s.closedPrice, 2389.9, reason: 'the broker\'s fill, not the tick');
      expect(s.brokerProfit, -510.0);
      expect(events.where((e) => e['type'] == 'history'), isNotEmpty);
    });

    test('a burst of ticks beyond the level reconciles only once', () async {
      await _seed([_trade()]);
      final engine = MonitorEngine(onEvent: (_) {}, checker: SignalChecker(trading: trading()));
      await engine.init();
      for (var i = 0; i < 10; i++) {
        await engine.handleTickForTest(Tick(time: _now, bid: 2385, ask: 2385.3, last: 2385));
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(requests.where((r) => r.url.path == '/reconcile'), hasLength(1));
    });

    test('ticks that do not cross anything cause no network traffic', () async {
      await _seed([_trade()]);
      final engine = MonitorEngine(onEvent: (_) {}, checker: SignalChecker(trading: trading()));
      await engine.init();
      await engine.handleTickForTest(Tick(time: _now, bid: 2405, ask: 2405.3, last: 2405));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(requests, isEmpty);
    });
  });

  test('broker fields survive a save and reload', () {
    final s = _trade()
      ..brokerProfit = 12.5
      ..closeReason = 'tp';
    final back = TradeSetup.fromJson(s.toJson());
    expect((back.brokerProfit, back.closeReason), (12.5, 'tp'));
    final legacy = s.toJson()
      ..remove('broker_profit')
      ..remove('close_reason');
    expect(TradeSetup.fromJson(legacy).brokerProfit, isNull);
  });
}
