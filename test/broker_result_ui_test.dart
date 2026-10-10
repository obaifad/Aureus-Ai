import 'package:aureus_ai/models/pivot.dart';
import 'package:aureus_ai/models/trade_setup.dart';
import 'package:aureus_ai/screens/trade_history_screen.dart';
import 'package:aureus_ai/services/history_store.dart';
import 'package:aureus_ai/services/signal_monitor.dart';
import 'package:aureus_ai/widgets/signal_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

TradeSetup _closed({double? profit, String? reason, DateTime? at}) => TradeSetup(
      symbol: 'XAUUSD',
      direction: TradeDirection.buy,
      timeframeLabel: '15M',
      setupType: SetupType.rangingBounce,
      entry: 2400,
      stopLoss: 2390,
      takeProfit: 2418,
      pattern: CandlePattern.bullishPinbar,
      detectedAt: at ?? DateTime.utc(2026, 10, 2, 9),
      outcome: TradeOutcome.win,
      closedPrice: 2418.4,
      closedAt: DateTime.utc(2026, 10, 2, 11),
      brokerProfit: profit,
      closeReason: reason,
      confluenceScore: 80,
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    dotenv.testLoad(fileInput: 'USE_MOCK_DATA=true');
  });

  group('wording', () {
    test('every broker close reason has plain words, and unknown ones have none', () {
      expect(_closed(reason: 'tp').closeReasonLabel, 'take profit hit');
      expect(_closed(reason: 'sl').closeReasonLabel, 'stop loss hit');
      expect(_closed(reason: 'stop_out').closeReasonLabel, 'broker stop-out');
      expect(_closed(reason: 'manual').closeReasonLabel, 'closed by hand');
      expect(_closed(reason: 'expert').closeReasonLabel, 'closed by the system');
      expect(_closed(reason: 'other').closeReasonLabel, 'closed by the broker');
      expect(_closed(reason: 'something-new').closeReasonLabel, isNull);
      expect(_closed().closeReasonLabel, isNull);
    });

    test('the net result is signed and rounded to cents', () {
      expect(_closed(profit: 480.5).brokerProfitLabel, '+480.50');
      expect(_closed(profit: -67.8).brokerProfitLabel, '-67.80');
      expect(_closed(profit: 0).brokerProfitLabel, '+0.00');
      expect(_closed().brokerProfitLabel, isNull);
    });
  });

  group('trade card', () {
    Future<void> show(WidgetTester tester, TradeSetup setup) => tester.pumpWidget(
          MaterialApp(home: Scaffold(body: SingleChildScrollView(child: SignalCard(setup: setup)))),
        );

    testWidgets('a trade closed by MT5 shows the broker\'s net result and why it closed', (tester) async {
      await show(tester, _closed(profit: 480.5, reason: 'tp'));
      expect(find.byKey(const Key('broker-result')), findsOneWidget);
      expect(find.text('MT5 net +480.50 · take profit hit'), findsOneWidget);
    });

    testWidgets('a loss shows its sign and reason', (tester) async {
      await show(tester, _closed(profit: -112.3, reason: 'sl'));
      expect(find.text('MT5 net -112.30 · stop loss hit'), findsOneWidget);
    });

    testWidgets('a trade with only a reason (or only a result) still shows what is known', (tester) async {
      await show(tester, _closed(reason: 'manual'));
      expect(find.text('closed by hand'), findsOneWidget);
      await show(tester, _closed(profit: 5));
      expect(find.text('MT5 net +5.00'), findsOneWidget);
    });

    testWidgets('a signal-only trade shows no broker line', (tester) async {
      await show(tester, _closed());
      expect(find.byKey(const Key('broker-result')), findsNothing);
    });
  });

  group('analytics', () {
    Future<void> openAnalytics(WidgetTester tester, List<TradeSetup> trades) async {
      // Real async (not the test's fake clock): the monitor's start-up history load must
      // FINISH, or it would leave HistoryStore's static lock held for the next test.
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
        ChangeNotifierProvider<SignalMonitor>.value(
            value: monitor, child: const MaterialApp(home: TradeHistoryScreen())),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));
    }

    testWidgets('the account result is the sum of MT5\'s own numbers', (tester) async {
      await openAnalytics(tester, [
        _closed(profit: 480.5, reason: 'tp', at: DateTime.utc(2026, 10, 2, 8)),
        _closed(profit: -112.3, reason: 'sl', at: DateTime.utc(2026, 10, 2, 9)),
      ]);
      expect(find.text('Net P/L (MT5)'), findsOneWidget);
      expect(find.text('+368.20'), findsOneWidget);
    });

    testWidgets('signal-only history has no MT5 result card', (tester) async {
      await openAnalytics(tester, [_closed()]);
      expect(find.text('Net P/L (MT5)'), findsNothing);
    });

    testWidgets('trades without an MT5 figure do not distort the sum', (tester) async {
      await openAnalytics(tester, [
        _closed(profit: 100, reason: 'tp', at: DateTime.utc(2026, 10, 2, 8)),
        _closed(at: DateTime.utc(2026, 10, 2, 9)),
      ]);
      expect(find.text('+100.00'), findsWidgets);
    });
  });
}
