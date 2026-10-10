import 'dart:convert';

import 'package:aureus_ai/config/app_config.dart';
import 'package:aureus_ai/models/pivot.dart';
import 'package:aureus_ai/models/trade_setup.dart';
import 'package:aureus_ai/screens/trade_history_screen.dart';
import 'package:aureus_ai/services/history_store.dart';
import 'package:aureus_ai/services/mt5_trading_service.dart';
import 'package:aureus_ai/services/notifier_service.dart';
import 'package:aureus_ai/services/signal_monitor.dart';
import 'package:aureus_ai/services/strategy_config_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _live = 'USE_MOCK_DATA=false\nDISABLE_MT5_BRIDGE=false\nBRIDGE_BASE_URL=http://bridge.test\n'
    'BRIDGE_API_KEY=bridge-secret-key-0123456789\n';

TradeSetup _trade({
  TradeDirection direction = TradeDirection.buy,
  TradeOutcome outcome = TradeOutcome.open,
  double? closedPrice,
  bool breakEven = false,
  double? brokerProfit,
  String? closeReason,
  DateTime? at,
}) =>
    TradeSetup(
      symbol: 'XAUUSD',
      direction: direction,
      timeframeLabel: '15M',
      setupType: SetupType.rangingBounce,
      entry: 2400,
      stopLoss: direction == TradeDirection.buy ? 2390 : 2410,
      takeProfit: direction == TradeDirection.buy ? 2418 : 2382,
      pattern: CandlePattern.bullishPinbar,
      detectedAt: at ?? DateTime.utc(2026, 10, 2, 9),
      outcome: outcome,
      closedPrice: closedPrice,
      closedAt: closedPrice == null ? null : DateTime.utc(2026, 10, 2, 11),
      breakEvenActive: breakEven,
      brokerProfit: brokerProfit,
      closeReason: closeReason,
      confluenceScore: 80,
    );

StrategyConfigSnapshot _snapshot(String mode) => StrategyConfigSnapshot.fromResponse({
      'revision': 5,
      'config': {
        'mode': {'auto_trade': mode, 'paused': false},
      },
    });

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    StrategyConfig.instance.resetForTesting();
    dotenv.testLoad(fileInput: 'USE_MOCK_DATA=true');
  });
  tearDown(() => StrategyConfig.instance.resetForTesting());

  group('the mode chosen on the control screen is what the app follows', () {
    test('Approval or Auto turns auto-trading on even though .env says false', () {
      dotenv.testLoad(fileInput: '${_live}ENABLE_AUTO_TRADING=false');
      for (final mode in ['approval', 'auto']) {
        StrategyConfig.instance.setSnapshot(_snapshot(mode));
        expect(AppConfig.enableAutoTrading, isTrue, reason: mode);
      }
    });

    test('Off turns it off even though .env says true', () {
      dotenv.testLoad(fileInput: '${_live}ENABLE_AUTO_TRADING=true');
      StrategyConfig.instance.setSnapshot(_snapshot('off'));
      expect(AppConfig.enableAutoTrading, isFalse);
    });

    test('with no bridge config at all, .env decides as before', () {
      dotenv.testLoad(fileInput: '${_live}ENABLE_AUTO_TRADING=true');
      expect(AppConfig.enableAutoTrading, isTrue);
      dotenv.testLoad(fileInput: '${_live}ENABLE_AUTO_TRADING=false');
      expect(AppConfig.enableAutoTrading, isFalse);
      expect(AppConfig.enableAutoTradingEnv, isFalse);
    });
  });

  group('opening an order', () {
    Future<(OrderResult, Map<String, dynamic>)> open(Map<String, dynamic> reply, {double? entry, bool sizing = false}) async {
      dotenv.testLoad(fileInput: _live);
      late Map<String, dynamic> sent;
      final client = MockClient((request) async {
        expect(request.url.path, '/order/open');
        sent = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(jsonEncode(reply), 200);
      });
      final result = await http.runWithClient(
        () => Mt5TradingService().openMarketOrder(
          direction: TradeDirection.buy,
          volume: 0.1,
          stopLoss: 2390,
          takeProfit: 2418,
          entry: entry,
          bridgeSizing: sizing,
        ),
        () => client,
      );
      return (result, sent);
    }

    test('the signal entry and bridge sizing are sent, and the lot the bridge used comes back', () async {
      final (result, sent) = await open({'success': true, 'ticket': 11, 'price': 2400.2, 'volume': 0.11}, entry: 2400.0, sizing: true);
      expect(sent['entry'], 2400.0);
      expect(sent['bridge_sizing'], isTrue);
      expect(sent['volume'], 0.1);
      expect(result.success, isTrue);
      expect(result.volume, 0.11);
      expect(result.ticket, 11);
    });

    test('without them the request is exactly what it was before', () async {
      final (result, sent) = await open({'success': true, 'ticket': 11, 'price': 2400.2});
      expect(sent.containsKey('entry'), isFalse);
      expect(sent.containsKey('bridge_sizing'), isFalse);
      expect(result.volume, isNull);
    });

    test('a refusal such as "price moved" is reported, not hidden', () async {
      final (result, _) = await open({'success': false, 'error': 'Price moved \$3.20 away from the signal (limit \$1.50)'}, entry: 2397, sizing: true);
      expect(result.success, isFalse);
      expect(result.error, contains('Price moved'));
    });
  });

  group('the closing notification', () {
    Future<String> outcomeText(TradeSetup setup) async {
      dotenv.testLoad(fileInput: _live);
      String? text;
      final client = MockClient((request) async {
        if (request.url.path == '/notify') text = (jsonDecode(request.body) as Map)['text'] as String;
        return http.Response(jsonEncode({'sent': true}), 200);
      });
      await http.runWithClient(() => NotifierService().sendOutcome(setup), () => client);
      return text!;
    }

    test('a trade closed by MT5 reports the broker\'s net result and why', () async {
      final text = await outcomeText(
          _trade(outcome: TradeOutcome.win, closedPrice: 2418, brokerProfit: 480.5, closeReason: 'tp'));
      expect(text, contains('Closed @ 2418.00 (+180.0 pips)'));
      expect(text, contains('MT5 net +480.50 · take profit hit'));
    });

    test('a loss reports its negative net result', () async {
      final text = await outcomeText(
          _trade(outcome: TradeOutcome.loss, closedPrice: 2390, brokerProfit: -112.3, closeReason: 'sl'));
      expect(text, contains('MT5 net -112.30 · stop loss hit'));
    });

    test('a signal-only trade keeps the short message', () async {
      final text = await outcomeText(_trade(outcome: TradeOutcome.win, closedPrice: 2418));
      expect(text, isNot(contains('MT5')));
      expect(text.trim().split('\n').length, 2); // title + one line
    });
  });

  group('break-even and manual closes in the analytics', () {
    test('a stop-out at Entry is break-even, a real stop-out is not', () {
      expect(_trade(outcome: TradeOutcome.loss, closedPrice: 2400, breakEven: true).isBreakEven, isTrue);
      expect(_trade(outcome: TradeOutcome.loss, closedPrice: 2400).isBreakEven, isTrue, reason: 'exit at entry');
      expect(_trade(outcome: TradeOutcome.loss, closedPrice: 2390).isBreakEven, isFalse);
      expect(_trade(outcome: TradeOutcome.win, closedPrice: 2418).isBreakEven, isFalse);
      expect(_trade(outcome: TradeOutcome.manualClose, closedPrice: 2400).isBreakEven, isFalse);
    });

    Future<void> openAnalytics(WidgetTester tester, List<TradeSetup> trades) async {
      final monitor = (await tester.runAsync(() async {
        await HistoryStore.mutate((h) {
          h.addAll(trades);
          return true;
        });
        final m = SignalMonitor();
        await Future<void>.delayed(const Duration(milliseconds: 150));
        return m;
      }))!;
      addTearDown(monitor.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider<SignalMonitor>.value(value: monitor, child: const MaterialApp(home: TradeHistoryScreen())),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));
    }

    testWidgets('the win rate leaves out break-even and hand-closed trades, which get their own cards', (tester) async {
      final t0 = DateTime.utc(2026, 10, 2, 6);
      await openAnalytics(tester, [
        for (var i = 0; i < 3; i++) _trade(outcome: TradeOutcome.win, closedPrice: 2418, at: t0.add(Duration(hours: i))),
        for (var i = 3; i < 5; i++) _trade(outcome: TradeOutcome.loss, closedPrice: 2390, at: t0.add(Duration(hours: i))),
        _trade(outcome: TradeOutcome.loss, closedPrice: 2400, breakEven: true, at: t0.add(const Duration(hours: 6))),
        _trade(outcome: TradeOutcome.manualClose, closedPrice: 2405, at: t0.add(const Duration(hours: 7))),
      ]);
      expect(find.text('60.0%'), findsWidgets, reason: '3 wins of 5 real results, not 3 of 7');
      expect(find.text('Break-even'), findsOneWidget);
      expect(find.text('Closed by hand'), findsOneWidget);
      expect(find.text('Total Trades'), findsOneWidget);
    });

    testWidgets('without such trades there are no extra cards', (tester) async {
      await openAnalytics(tester, [_trade(outcome: TradeOutcome.win, closedPrice: 2418)]);
      expect(find.text('Break-even'), findsNothing);
      expect(find.text('Closed by hand'), findsNothing);
    });
  });
}
