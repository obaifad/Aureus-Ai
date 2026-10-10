import 'package:aureus_ai/models/pivot.dart';
import 'package:aureus_ai/models/trade_setup.dart';
import 'package:aureus_ai/services/signal_monitor.dart';
import 'package:aureus_ai/widgets/close_trade_flow.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

TradeSetup _trade({int? ticket}) => TradeSetup(
      symbol: 'XAUUSD',
      direction: TradeDirection.buy,
      timeframeLabel: '15M',
      setupType: SetupType.rangingBounce,
      entry: 2400,
      stopLoss: 2390,
      takeProfit: 2418,
      pattern: CandlePattern.bullishPinbar,
      detectedAt: DateTime.utc(2026, 10, 2, 10),
      brokerTicket: ticket,
    );

void main() {
  late SignalMonitor monitor;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    dotenv.testLoad(fileInput: 'USE_MOCK_DATA=true');
    monitor = SignalMonitor();
  });
  tearDown(() => monitor.dispose());

  Future<void> open(WidgetTester tester, TradeSetup trade) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            key: const Key('go'),
            onPressed: () => confirmAndCloseTrade(context, monitor, trade),
            child: const Text('close'),
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const Key('go')));
    await tester.pumpAndSettle();
  }

  testWidgets('a real MT5 position is described as a real, irreversible close', (tester) async {
    await open(tester, _trade(ticket: 777));
    expect(find.byKey(const Key('close-trade-dialog')), findsOneWidget);
    expect(find.textContaining('REAL MT5 position #777'), findsOneWidget);
  });

  testWidgets('a signal-only trade is described as such', (tester) async {
    await open(tester, _trade());
    expect(find.textContaining('signal-only trade'), findsOneWidget);
    expect(find.textContaining('REAL MT5'), findsNothing);
  });

  testWidgets('Cancel closes nothing and shows no result', (tester) async {
    await open(tester, _trade(ticket: 777));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('confirming reports when there is no live price yet instead of failing silently', (tester) async {
    await open(tester, _trade(ticket: 777));
    await tester.tap(find.byKey(const Key('close-trade-confirm')));
    await tester.pumpAndSettle();
    expect(find.textContaining('No live price yet'), findsOneWidget);
  });
}
