import 'package:aureus_ai/models/pivot.dart';
import 'package:aureus_ai/models/trade_setup.dart';
import 'package:aureus_ai/screens/home_screen.dart';
import 'package:aureus_ai/screens/strategy_control_screen.dart';
import 'package:aureus_ai/services/pending_store.dart';
import 'package:aureus_ai/services/signal_monitor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

TradeSetup _setup() => TradeSetup(
      symbol: 'XAUUSD',
      direction: TradeDirection.sell,
      timeframeLabel: '15M',
      setupType: SetupType.rangingBounce,
      entry: 2412.5,
      stopLoss: 2420.0,
      takeProfit: 2399.0,
      pattern: CandlePattern.bearishPinbar,
      detectedAt: DateTime.utc(2026, 10, 2, 11, 59),
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    dotenv.testLoad(fileInput: 'USE_MOCK_DATA=true');
  });

  Future<void> openHome(WidgetTester tester) async {
    // Real async so the monitor's start-up load FINISHES and cannot leave a store lock held.
    final monitor = (await tester.runAsync(() async {
      final m = SignalMonitor();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      return m;
    }))!;
    addTearDown(monitor.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<SignalMonitor>.value(value: monitor, child: const MaterialApp(home: HomeScreen())),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('a proposal waiting on Telegram is shown at the top of the home screen', (tester) async {
    await tester.runAsync(() => PendingStore.add(PendingApproval(
          setup: _setup(),
          engineId: 'range_bounce',
          submittedAt: DateTime.utc(2026, 10, 2, 12),
          expiresAt: DateTime.utc(2026, 10, 2, 12, 1, 30),
        )));
    await openHome(tester);
    expect(find.byKey(const Key('pending-approval-banner')), findsOneWidget);
    expect(find.text('Waiting for your approval on Telegram'), findsOneWidget);
    expect(find.textContaining('SELL XAUUSD @ 2412.50'), findsOneWidget);
    expect(find.textContaining('SL 2420.00 · TP 2399.00'), findsOneWidget);
    expect(find.textContaining('Decide before'), findsOneWidget);
  });

  testWidgets('nothing waiting means no banner', (tester) async {
    await openHome(tester);
    expect(find.byKey(const Key('pending-approval-banner')), findsNothing);
  });

  testWidgets('the Strategy Control Center is one tap away in the home menu', (tester) async {
    await openHome(tester);
    await tester.tap(find.byIcon(Icons.more_vert));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.text('Strategy Control Center'), findsOneWidget);
    await tester.tap(find.text('Strategy Control Center'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(find.byType(StrategyControlScreen), findsOneWidget);
  });
}
