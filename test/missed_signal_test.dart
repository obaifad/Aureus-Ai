import 'dart:convert';

import 'package:aureus_ai/models/pivot.dart';
import 'package:aureus_ai/models/trade_setup.dart';
import 'package:aureus_ai/screens/trade_history_screen.dart';
import 'package:aureus_ai/services/history_store.dart';
import 'package:aureus_ai/services/notifier_service.dart';
import 'package:aureus_ai/services/signal_monitor.dart';
import 'package:aureus_ai/widgets/signal_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _live = 'USE_MOCK_DATA=false\nDISABLE_MT5_BRIDGE=false\nBRIDGE_BASE_URL=http://bridge.test\n'
    'BRIDGE_API_KEY=bridge-secret-key-0123456789\n';

/// A BUY at 2400 with stop 2390 and target 2418 (1:1.8).
TradeSetup _signal({
  String? missed,
  TradeOutcome outcome = TradeOutcome.open,
  double? closedPrice,
  DateTime? at,
  int? ticket,
}) =>
    TradeSetup(
      symbol: 'XAUUSD',
      direction: TradeDirection.buy,
      timeframeLabel: '15M',
      setupType: SetupType.rangingBounce,
      entry: 2400,
      stopLoss: 2390,
      takeProfit: 2418,
      pattern: CandlePattern.bullishPinbar,
      detectedAt: at ?? DateTime.utc(2026, 10, 5, 0),
      outcome: outcome,
      closedPrice: closedPrice,
      closedAt: closedPrice == null ? null : DateTime.utc(2026, 10, 5, 0, 11),
      confluenceScore: 64,
      notTradedReason: missed,
      brokerTicket: ticket,
      aiReason: '• Not traded: test.',
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    dotenv.testLoad(fileInput: 'USE_MOCK_DATA=true');
  });

  group('the model', () {
    test('a not-traded signal survives a save and reload', () {
      final back = TradeSetup.fromJson(jsonDecode(jsonEncode(_signal(missed: 'expired').toJson())) as Map<String, dynamic>);
      expect(back.notTradedReason, 'expired');
      expect(back.isMissed, isTrue);
    });

    test('history saved before the field existed loads as real trades', () {
      final json = _signal().toJson()..remove('not_traded_reason');
      expect(TradeSetup.fromJson(json).isMissed, isFalse);
      expect(TradeSetup.fromJson(json).notTradedLabel, isNull);
    });

    test('every reason has plain words', () {
      expect(_signal(missed: 'expired').notTradedLabel, 'Approval expired');
      expect(_signal(missed: 'rejected').notTradedLabel, 'You rejected it');
      expect(_signal(missed: 'blocked').notTradedLabel, 'Blocked by the bridge');
      expect(_signal(missed: 'failed').notTradedLabel, 'Order failed');
    });

    test('it cannot be closed by hand: there is nothing to close', () {
      final setup = _signal(missed: 'expired');
      expect(setup.closeTradeManually(2405), isFalse);
      expect(setup.outcome, TradeOutcome.open);
      expect(_signal().closeTradeManually(2405), isTrue, reason: 'a real trade still can');
    });

    test('the outcome ribbon says what it would have done, not that a trade closed', () {
      expect(_signal(missed: 'expired', outcome: TradeOutcome.win, closedPrice: 2418).outcomeLabel, '🎯 Would have hit TP');
      expect(_signal(missed: 'expired', outcome: TradeOutcome.loss, closedPrice: 2390).outcomeLabel, '🛑 Would have hit SL');
      expect(_signal(outcome: TradeOutcome.win, closedPrice: 2418).outcomeLabel, '🎯 TP Hit');
      expect(_signal(missed: 'expired').outcomeLabel, isNull, reason: 'still running');
    });

    test('a missed winner explains what it would have made and what to do about it', () {
      final win = _signal(missed: 'expired', outcome: TradeOutcome.win, closedPrice: 2418);
      expect(win.postMortemReason, contains('would have made +180.0 pips'));
      expect(win.postMortemReason, contains('Approval expired'));
      expect(win.postMortemAdvice, contains('expired before you answered'));
      expect(_signal(missed: 'blocked', outcome: TradeOutcome.win, closedPrice: 2418).postMortemAdvice,
          contains('Late-approval tolerance'));
      expect(_signal(missed: 'rejected', outcome: TradeOutcome.win, closedPrice: 2418).postMortemAdvice,
          contains('You rejected a winner'));
      expect(_signal(missed: 'failed', outcome: TradeOutcome.win, closedPrice: 2418).postMortemAdvice,
          contains('broker refused'));
    });

    test('an avoided loss says so', () {
      final loss = _signal(missed: 'rejected', outcome: TradeOutcome.loss, closedPrice: 2390);
      expect(loss.postMortemReason, contains('skipping it avoided -100.0 pips'));
      expect(loss.postMortemAdvice, 'Nothing to change: this one would have lost.');
    });

    test('while it is still running there is nothing to explain yet', () {
      final running = _signal(missed: 'expired');
      expect(running.postMortemReason, isNull);
      expect(running.postMortemAdvice, isNull);
    });

    test('a real trade keeps its own post-mortem', () {
      final real = _signal(outcome: TradeOutcome.win, closedPrice: 2418);
      expect(real.postMortemReason, contains('Take-Profit hit at 1:1.8'));
    });
  });

  group('the notification for a missed signal', () {
    Future<List<String>> sentFor(TradeSetup setup) async {
      dotenv.testLoad(fileInput: _live);
      final texts = <String>[];
      final client = MockClient((request) async {
        if (request.url.path == '/notify') texts.add((jsonDecode(request.body) as Map)['text'] as String);
        return http.Response(jsonEncode({'sent': true}), 200);
      });
      await http.runWithClient(() => NotifierService().sendOutcome(setup), () => client);
      return texts;
    }

    test('a missed winner is announced as missed, never as a closed trade', () async {
      final texts = await sentFor(_signal(missed: 'expired', outcome: TradeOutcome.win, closedPrice: 2418));
      final text = texts.single;
      expect(text, contains('Missed a winner'));
      expect(text, contains('Not traded (Approval expired). It would have hit TP @ 2418.00 (+180.0 pips).'));
      expect(text, isNot(contains('Closed @')));
      expect(text, isNot(contains('MT5 net')));
    });

    test('an avoided loss is announced as such', () async {
      final text = (await sentFor(_signal(missed: 'blocked', outcome: TradeOutcome.loss, closedPrice: 2390))).single;
      expect(text, contains('Avoided a loss'));
      expect(text, contains('It hit SL @ 2390.00 (-100.0 pips)'));
    });

    test('a signal you rejected yourself is not sent to Telegram (a decision you already know)', () async {
      expect(await sentFor(_signal(missed: 'rejected', outcome: TradeOutcome.win, closedPrice: 2418)), isEmpty);
    });

    test('a real trade is announced exactly as before', () async {
      final text = (await sentFor(_signal(outcome: TradeOutcome.win, closedPrice: 2418))).single;
      expect(text, contains('Closed @ 2418.00 (+180.0 pips)'));
    });
  });

  group('the trade card', () {
    Future<void> show(WidgetTester tester, TradeSetup setup, {VoidCallback? onClose}) async {
      // Real async (not the test's fake clock): the monitor's start-up history load must FINISH, or it would
      // leave HistoryStore's static lock held for the next test.
      final monitor = (await tester.runAsync(() async {
        final m = SignalMonitor();
        await Future<void>.delayed(const Duration(milliseconds: 150));
        return m;
      }))!;
      addTearDown(monitor.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChangeNotifierProvider<SignalMonitor>.value(
              value: monitor,
              child: SingleChildScrollView(child: SignalCard(setup: setup, onCloseTrade: onClose)),
            ),
          ),
        ),
      );
    }

    testWidgets('says it was not traded and why, and offers no way to close it', (tester) async {
      await show(tester, _signal(missed: 'expired'), onClose: null);
      expect(find.byKey(const Key('not-traded-chip')), findsOneWidget);
      expect(find.text('📭 Not traded — Approval expired'), findsOneWidget);
      expect(find.text('Close Trade'), findsNothing);
      expect(find.textContaining('If taken'), findsNothing, reason: 'no price yet in this test; counter shows its waiting text');
    });

    testWidgets('a finished one shows what it would have done', (tester) async {
      await show(tester, _signal(missed: 'expired', outcome: TradeOutcome.win, closedPrice: 2418));
      expect(find.text('🎯 Would have hit TP'), findsOneWidget);
      expect(find.byKey(const Key('not-traded-chip')), findsOneWidget);
    });

    testWidgets('a real trade has no such chip', (tester) async {
      await show(tester, _signal(outcome: TradeOutcome.win, closedPrice: 2418));
      expect(find.byKey(const Key('not-traded-chip')), findsNothing);
      expect(find.text('🎯 TP Hit'), findsOneWidget);
    });
  });

  group('the analytics', () {
    Future<void> openAnalytics(WidgetTester tester, List<TradeSetup> trades) async {
      // Tall enough that the whole list is built (a ListView only builds what is on screen).
      tester.view.physicalSize = const Size(900, 3200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
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

    testWidgets('missed signals are summarised apart and change none of the real figures', (tester) async {
      final t0 = DateTime.utc(2026, 10, 2, 6);
      await openAnalytics(tester, [
        _signal(outcome: TradeOutcome.win, closedPrice: 2418, at: t0, ticket: 1),
        _signal(outcome: TradeOutcome.loss, closedPrice: 2390, at: t0.add(const Duration(hours: 1)), ticket: 2),
        _signal(missed: 'expired', outcome: TradeOutcome.win, closedPrice: 2418, at: t0.add(const Duration(hours: 2))),
        _signal(missed: 'rejected', outcome: TradeOutcome.loss, closedPrice: 2390, at: t0.add(const Duration(hours: 3))),
        _signal(missed: 'blocked', at: t0.add(const Duration(hours: 4))),
      ]);
      // Real figures: 2 trades, 1 win of 2 -> 50%, +180 - 100 = +80 pips.
      expect(find.text('Total Trades'), findsOneWidget);
      expect(find.text('2'), findsWidgets);
      expect(find.text('50.0%'), findsWidgets);
      expect(find.text('+80.0'), findsWidgets);
      // The missed ones: 3 of them, 1 would have won, 1 would have lost, 1 is still running; +80 pips.
      expect(find.byKey(const Key('missed-summary')), findsOneWidget);
      expect(find.text('Missed signals (not traded): 3'), findsOneWidget);
      expect(find.textContaining('would have been 1 win / 1 loss · +80.0 pips · 1 still running'), findsOneWidget);
      expect(find.text('Not included in the figures above.'), findsOneWidget);
    });

    testWidgets('each missed signal is marked in the list', (tester) async {
      await openAnalytics(tester, [
        _signal(missed: 'expired', outcome: TradeOutcome.win, closedPrice: 2418),
        _signal(outcome: TradeOutcome.win, closedPrice: 2418, at: DateTime.utc(2026, 10, 5, 3), ticket: 1),
      ]);
      expect(find.text('MISSED'), findsOneWidget);
      expect(find.byKey(const Key('missed-line')), findsOneWidget);
      expect(find.text('Not traded — Approval expired · would have hit TP'), findsOneWidget);
    });

    testWidgets('without missed signals there is no extra card', (tester) async {
      await openAnalytics(tester, [_signal(outcome: TradeOutcome.win, closedPrice: 2418, ticket: 1)]);
      expect(find.byKey(const Key('missed-summary')), findsNothing);
      expect(find.text('MISSED'), findsNothing);
    });

    testWidgets('only missed signals: the real figures are all zero', (tester) async {
      await openAnalytics(tester, [_signal(missed: 'expired', outcome: TradeOutcome.win, closedPrice: 2418)]);
      expect(find.text('Missed signals (not traded): 1'), findsOneWidget);
      expect(find.text('+0.0'), findsWidgets, reason: 'total / week / today pips ignore the missed signal');
      expect(find.text('—'), findsWidgets, reason: 'no real results, so no win rate');
    });
  });
}
