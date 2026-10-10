import 'package:aureus_ai/models/pivot.dart';
import 'package:aureus_ai/models/trade_setup.dart';
import 'package:aureus_ai/utils/trade_time_format.dart';
import 'package:aureus_ai/widgets/signal_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('formatter', () {
    final friday = DateTime(2026, 10, 2, 17, 31); // local time, a Friday
    test('header: numeric date, English weekday, then the time', () {
      expect(TradeTimeFormat.header(friday), '02.10.2026 - Friday | 17:31');
    });
    test('exit stamp: same date and weekday, time after a space', () {
      expect(TradeTimeFormat.exitStamp(DateTime(2026, 10, 2, 17, 57)), '02.10.2026 - Friday 17:57');
    });
    test('zero-padded day and month, and every weekday in English', () {
      expect(TradeTimeFormat.dateWithWeekday(DateTime(2026, 1, 5)), '05.01.2026 - Monday');
      const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
      for (var i = 0; i < 7; i++) {
        expect(TradeTimeFormat.dateWithWeekday(DateTime(2026, 10, 5 + i)), endsWith(days[i]));
      }
    });
    test('UTC input is shown in local time', () {
      final utc = DateTime.utc(2026, 10, 2, 12);
      expect(TradeTimeFormat.header(utc), TradeTimeFormat.header(utc.toLocal()));
    });
  });

  testWidgets('the card shows the new header and exit line', (tester) async {
    final setup = TradeSetup(
      symbol: 'XAUUSD',
      direction: TradeDirection.buy,
      timeframeLabel: '15M',
      setupType: SetupType.rangingBounce,
      entry: 4130,
      stopLoss: 4125.92,
      takeProfit: 4140,
      pattern: CandlePattern.bullishPinbar,
      detectedAt: DateTime(2026, 10, 2, 17, 31),
      outcome: TradeOutcome.loss,
      closedPrice: 4125.92,
      closedAt: DateTime(2026, 10, 2, 17, 57),
    );
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: SignalCard(setup: setup)))));
    expect(find.text('02.10.2026 - Friday | 17:31'), findsOneWidget);
    expect(find.textContaining('Exit 4125.92 · 02.10.2026 - Friday 17:57'), findsOneWidget);
  });
}
