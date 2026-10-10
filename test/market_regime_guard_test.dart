import 'package:aureus_ai/models/candle.dart';
import 'package:aureus_ai/models/pivot.dart' show TradeDirection;
import 'package:aureus_ai/services/market_regime_guard.dart';
import 'package:aureus_ai/services/ta_engine.dart';
import 'package:flutter_test/flutter_test.dart';

Candle _c(DateTime t, double o, double h, double l, double c, {double? spread}) =>
    Candle(time: t, open: o, high: h, low: l, close: c, volume: 1, spreadPips: spread);

void main() {
  group('atrSeries', () {
    test('its last element equals TaEngine.averageTrueRange', () {
      final start = DateTime.utc(2026, 10, 1);
      final candles = [
        for (var i = 0; i < 60; i++)
          _c(start.add(Duration(minutes: 15 * i)), 2400.0 + i % 7, 2403.0 + i % 5, 2397.0 - i % 3, 2401.0 + i % 4),
      ];
      final series = atrSeries(candles);
      expect(series.last, closeTo(TaEngine().averageTrueRange(candles)!, 1e-9));
      expect(series[13], isNull); // needs period + 1 candles
      expect(series[14], isNotNull);
    });
  });

  group('ImpulseDetector', () {
    const detector = ImpulseDetector();
    const params = ImpulseParams(); // 3 candles, body >= 0.6 range and >= 0.7 ATR, shock > 3 ATR, 2h / 4h
    final start = DateTime.utc(2026, 10, 6, 6);

    /// 30 quiet candles with a $4 range (ATR ~ 4), then [tail] one by one.
    List<Candle> series(List<List<double>> tail) {
      final out = <Candle>[
        for (var i = 0; i < 30; i++) _c(start.add(Duration(minutes: 15 * i)), 2400, 2402, 2398, 2400.5),
      ];
      for (final o in tail) {
        out.add(_c(start.add(Duration(minutes: 15 * out.length)), o[0], o[1], o[2], o[3]));
      }
      return out;
    }

    DateTime closeOf(List<Candle> c) => c.last.time.add(const Duration(minutes: 15));

    ImpulseVerdict assess(List<Candle> m15, {DateTime? at, ImpulseParams p = params, List<Candle> m5 = const []}) =>
        detector.assess(m15: m15, m5: m5, nowUtc: at ?? closeOf(m15), params: p);

    test('a quiet market has no impulse', () {
      expect(assess(series([])).isActive, isFalse);
    });

    test('three consecutive high-momentum candles are a bullish impulse that restricts a SELL, not a BUY', () {
      final m15 = series([
        [2400, 2405.2, 2399.8, 2405], // body 5 of 5.4 range, 1.25 ATR
        [2405, 2410.2, 2404.8, 2410],
        [2410, 2415.2, 2409.8, 2415],
      ]);
      final verdict = assess(m15);
      expect(verdict.isActive, isTrue);
      final event = verdict.active.single;
      expect((event.direction, event.kind, event.timeframe), (TradeDirection.buy, ImpulseKind.momentumRun, 'M15'));
      expect(event.endsAt, closeOf(m15));
      expect(event.restrictUntil, closeOf(m15).add(const Duration(hours: 2)));
      expect(verdict.blockerFor(TradeDirection.sell), isNotNull); // counter-trend
      expect(verdict.blockerFor(TradeDirection.buy), isNull); // with the impulse
    });

    test('a bearish impulse restricts a BUY', () {
      final m15 = series([
        [2400, 2400.2, 2394.8, 2395],
        [2395, 2395.2, 2389.8, 2390],
        [2390, 2390.2, 2384.8, 2385],
      ]);
      final verdict = assess(m15);
      expect(verdict.active.single.direction, TradeDirection.sell);
      expect(verdict.blockerFor(TradeDirection.buy), isNotNull);
      expect(verdict.blockerFor(TradeDirection.sell), isNull);
    });

    test('two momentum candles are not enough, nor is a run broken by a weak or opposite candle', () {
      expect(
        assess(series([
          [2400, 2405.2, 2399.8, 2405],
          [2405, 2410.2, 2404.8, 2410],
        ])).isActive,
        isFalse,
      );
      // the middle candle is a pin bar: body 1.5 of a 6 range
      expect(
        assess(series([
          [2400, 2405.2, 2399.8, 2405],
          [2405, 2411, 2405, 2406.5],
          [2406.5, 2411.7, 2406.3, 2411.5],
        ])).isActive,
        isFalse,
      );
      // the middle candle is strong but BEARISH
      expect(
        assess(series([
          [2400, 2405.2, 2399.8, 2405],
          [2405, 2405.2, 2399.8, 2400],
          [2400, 2405.2, 2399.8, 2405],
        ])).isActive,
        isFalse,
      );
    });

    test('a body smaller than 0.7 ATR is not high momentum even with a clean shape', () {
      // body 2.4 of a 2.6 range: a great shape but only 0.6 ATR
      final m15 = series([
        [2400, 2402.5, 2399.9, 2402.4],
        [2402.4, 2404.9, 2402.3, 2404.8],
        [2404.8, 2407.3, 2404.7, 2407.2],
      ]);
      expect(assess(m15).isActive, isFalse);
    });

    test('a single shock candle larger than 3 ATR is an impulse on its own and restricts for 4 hours', () {
      final m15 = series([
        [2400, 2415, 2399, 2414], // range 16 = 4 x ATR(4), body 14
      ]);
      final verdict = assess(m15);
      final event = verdict.active.single;
      expect((event.kind, event.direction), (ImpulseKind.shockCandle, TradeDirection.buy));
      expect(event.restrictUntil, closeOf(m15).add(const Duration(hours: 4)));
      expect(event.magnitudeAtr, closeTo(16 / 4, 0.01)); // judged against the ATR BEFORE it, not one it inflated
    });

    test('a candle exactly 3 ATR tall is not a shock', () {
      expect(assess(series([[2400, 2412, 2400, 2411]])).active.where((e) => e.kind == ImpulseKind.shockCandle), isEmpty);
    });

    test('a huge range that closed where it opened is a spike, not an impulse', () {
      expect(assess(series([[2400, 2415, 2385, 2400.5]])).isActive, isFalse);
    });

    test('the restriction ends exactly when its window does', () {
      final m15 = series([[2400, 2415, 2399, 2414]]);
      final end = closeOf(m15);
      expect(assess(m15, at: end).isActive, isTrue);
      expect(assess(m15, at: end.add(const Duration(hours: 3, minutes: 59))).isActive, isTrue);
      expect(assess(m15, at: end.add(const Duration(hours: 4))).isActive, isFalse);
    });

    test('a run is released after 2 hours, sooner than a shock', () {
      final m15 = series([
        [2400, 2405.2, 2399.8, 2405],
        [2405, 2410.2, 2404.8, 2410],
        [2410, 2415.2, 2409.8, 2415],
      ]);
      expect(assess(m15, at: closeOf(m15).add(const Duration(hours: 1, minutes: 59))).isActive, isTrue);
      expect(assess(m15, at: closeOf(m15).add(const Duration(hours: 2))).isActive, isFalse);
    });

    test('two opposite impulses inside their windows restrict BOTH directions', () {
      final m15 = series([
        [2400, 2415, 2399, 2414], // bullish shock
        [2414, 2415, 2397, 2398], // bearish shock
      ]);
      final verdict = assess(m15);
      expect(verdict.active.length, 2);
      expect(verdict.blockerFor(TradeDirection.buy), isNotNull);
      expect(verdict.blockerFor(TradeDirection.sell), isNotNull);
      expect(verdict.active.first.direction, TradeDirection.sell); // newest first
    });

    test('the thresholds are the config\'s: 2 candles, a different shock size', () {
      final two = series([
        [2400, 2405.2, 2399.8, 2405],
        [2405, 2410.2, 2404.8, 2410],
      ]);
      expect(assess(two, p: const ImpulseParams(consecutive: 2)).isActive, isTrue);
      final shock = series([[2400, 2411, 2400, 2410.5]]); // range 11: under 3 x ATR(4) = 12, over 2.5 x = 10
      expect(assess(shock).isActive, isFalse);
      expect(assess(shock, p: const ImpulseParams(shockAtr: 2.5)).isActive, isTrue);
    });

    test('5M candles are read too, from their own close time', () {
      final quietM5 = <Candle>[
        for (var i = 0; i < 30; i++) _c(start.add(Duration(minutes: 5 * i)), 2400, 2401, 2399, 2400.2),
      ];
      final m5 = [...quietM5, _c(start.add(const Duration(minutes: 150)), 2400, 2409, 2399.5, 2408.5)];
      final m15 = series([]);
      final now = start.add(const Duration(minutes: 155));
      final verdict = detector.assess(m15: m15, m5: m5, nowUtc: now, params: params);
      final event = verdict.active.single;
      expect((event.timeframe, event.kind, event.direction), ('M5', ImpulseKind.shockCandle, TradeDirection.buy));
      expect(event.endsAt, now);
      // without the 5M feed the same market has no opinion
      expect(detector.assess(m15: m15, nowUtc: now, params: params).isActive, isFalse);
    });

    test('too little history means no impulse rather than an error', () {
      expect(assess(series([]).sublist(0, 10)).isActive, isFalse);
    });

    test('an event describes itself for the log', () {
      final m15 = series([[2400, 2415, 2399, 2414]]);
      final text = assess(m15).active.single.label;
      expect(text, allOf(contains('bullish'), contains('shock candle'), contains('M15'), contains('4.0×ATR')));
    });
  });

  group('VolatilityBaseline', () {
    /// [days] days of 15M candles from 2026-09-01 whose range is [rangeOf](day, slot).
    List<Candle> history(int days, double Function(int day, int slot) rangeOf, {double? Function(int day, int slot)? spreadOf}) {
      final out = <Candle>[];
      for (var d = 0; d < days; d++) {
        for (var s = 0; s < 96; s++) {
          final t = DateTime.utc(2026, 9, 1 + d).add(Duration(minutes: 15 * s));
          final r = rangeOf(d, s);
          out.add(_c(t, 2400, 2400 + r, 2400, 2400 + r / 2, spread: spreadOf?.call(d, s)));
        }
      }
      return out;
    }

    final now = DateTime.utc(2026, 9, 30, 12);

    test('the median is per time-of-day slot', () {
      final b = VolatilityBaseline.build(history(25, (d, s) => s < 48 ? 4 : 10), nowUtc: now);
      expect(b.medianRange(DateTime.utc(2026, 9, 27, 3, 0)), 4); // an early slot
      expect(b.medianRange(DateTime.utc(2026, 9, 27, 15, 0)), 10); // an afternoon slot
      expect(VolatilityBaseline.slotOf(DateTime.utc(2026, 9, 27, 15, 7)), 15 * 4 + 0);
    });

    test('only strictly EARLIER days count: the candle\'s own day and any later day are ignored', () {
      // day 24 (Sep 25) is a monster; the median for Sep 25 itself must not see it
      final b = VolatilityBaseline.build(history(26, (d, s) => d == 24 ? 90 : 5), nowUtc: now);
      expect(b.medianRange(DateTime.utc(2026, 9, 25, 9)), 5);
      expect(b.medianRange(DateTime.utc(2026, 9, 26, 9)), 5); // one outlier day in 20 does not move a median
      expect(b.sampleCount(DateTime.utc(2026, 9, 25, 9)), 20); // capped at 20 days
    });

    test('only the most recent N days are used', () {
      // ranges grow day by day: 1, 2, 3 ... so a 20-day window ends at the day before
      final b = VolatilityBaseline.build(history(30, (d, s) => d + 1.0), nowUtc: now, days: 20);
      // for Oct 1 (day index 30) the prior 20 days are indexes 10..29 -> ranges 11..30, median 20.5
      expect(b.medianRange(DateTime.utc(2026, 10, 1, 9)), 20.5);
      final short = VolatilityBaseline.build(history(30, (d, s) => d + 1.0), nowUtc: now, days: 10);
      expect(short.medianRange(DateTime.utc(2026, 10, 1, 9)), 25.5); // days 20..29 -> 21..30
    });

    test('fewer than 8 same-slot samples is no baseline at all', () {
      final b = VolatilityBaseline.build(history(8, (d, s) => 5), nowUtc: now);
      expect(b.medianRange(DateTime.utc(2026, 9, 9, 9)), 5); // 8 earlier days: just enough
      expect(b.medianRange(DateTime.utc(2026, 9, 8, 9)), isNull); // only 7
    });

    test('flat candles (a closed market) are left out of the median', () {
      final b = VolatilityBaseline.build(
        history(25, (d, s) => d.isEven ? 0 : 6), // every other day is flat
        nowUtc: now,
      );
      expect(b.medianRange(DateTime.utc(2026, 9, 26, 9)), 6);
    });

    test('the spread median needs spread data, and ignores zero spreads', () {
      final none = VolatilityBaseline.build(history(25, (d, s) => 5), nowUtc: now);
      expect(none.medianSpread(DateTime.utc(2026, 9, 26, 9)), isNull);
      final some = VolatilityBaseline.build(history(25, (d, s) => 5, spreadOf: (d, s) => d % 5 == 0 ? 0 : 2.5), nowUtc: now);
      expect(some.medianSpread(DateTime.utc(2026, 9, 26, 9)), 2.5);
    });
  });

  group('ChaosDetector', () {
    const detector = ChaosDetector();
    const params = ChaosParams(); // 3x range, 3x spread, 20 days, 15 minute pause

    // 21 trading days where every candle ranges $6 (spread 2.5 pips) — the normal everywhere.
    final base = DateTime.utc(2026, 9, 1);
    List<Candle> calm({double range = 6, double spread = 2.5}) => [
          for (var d = 0; d < 21; d++)
            for (var s = 0; s < 96; s++)
              _c(base.add(Duration(days: d, minutes: 15 * s)), 2400, 2400 + range, 2400, 2400 + range / 2, spread: spread),
        ];

    final now = DateTime.utc(2026, 9, 22, 10, 7); // inside the 10:00 candle
    final baseline = VolatilityBaseline.build(calm(), nowUtc: now);

    /// Today's closed candles up to 09:45 (the last closed one at [now]) plus an optional forming candle.
    List<Candle> today({double lastRange = 6, double? lastSpread, int closedCount = 40}) {
      final day = DateTime.utc(2026, 9, 22);
      return [
        for (var s = 0; s < closedCount; s++)
          _c(
            day.add(Duration(minutes: 15 * s)),
            2400,
            2400 + (s == closedCount - 1 ? lastRange : 6),
            2400,
            2403,
            spread: s == closedCount - 1 ? lastSpread : null,
          ),
      ];
    }

    ChaosVerdict assess(
      List<Candle> closed, {
      Candle? forming,
      VolatilityBaseline? b,
      DateTime? at,
      double? live,
      ChaosParams p = params,
    }) =>
        detector.assess(
          closed15m: closed,
          forming: forming,
          baseline: b ?? baseline,
          nowUtc: at ?? now,
          liveSpreadPips: live,
          params: p,
        );

    test('a normal market is not stressed, and says it had a baseline to judge by', () {
      final v = assess(today());
      expect((v.stressed, v.baselineReady, v.reason), (false, true, 'normal'));
      expect(v.rangeRatio, closeTo(1.0, 1e-9));
    });

    test('a candle 3x its time-of-day median is chaos, at exactly the multiple too', () {
      final at3 = assess(today(lastRange: 18));
      expect(at3.stressed, isTrue);
      expect(at3.rangeRatio, closeTo(3.0, 1e-9));
      expect(at3.reason, allOf(contains('09:45 UTC'), contains('3.0×'), contains('20-day median')));
      expect(assess(today(lastRange: 17.9)).stressed, isFalse);
    });

    test('the SAME absolute range is normal in a busy slot and chaos in a quiet one (time-adjusted)', () {
      final mixed = VolatilityBaseline.build(
        [
          for (var d = 0; d < 21; d++)
            for (var s = 0; s < 96; s++)
              _c(base.add(Duration(days: d, minutes: 15 * s)), 2400, 2400 + (s < 48 ? 4 : 12), 2400, 2402),
        ],
        nowUtc: now,
      );
      final day = DateTime.utc(2026, 9, 22);
      Candle at(int slot) => _c(day.add(Duration(minutes: 15 * slot)), 2400, 2412, 2400, 2406);
      final closedQuiet = [for (var s = 0; s < 20; s++) _c(day.add(Duration(minutes: 15 * s)), 2400, 2404, 2400, 2402), at(20)];
      final closedBusy = [for (var s = 0; s < 60; s++) _c(day.add(Duration(minutes: 15 * s)), 2400, 2412, 2400, 2406), at(60)];
      // a $12 candle at 05:00 UTC (quiet slot, median 4) is 3x; at 15:00 UTC (busy slot, median 12) it is 1x
      expect(assess(closedQuiet, b: mixed, at: day.add(const Duration(minutes: 15 * 21, seconds: 30))).stressed, isTrue);
      expect(assess(closedBusy, b: mixed, at: day.add(const Duration(minutes: 15 * 61, seconds: 30))).stressed, isFalse);
    });

    test('the still-forming candle counts as soon as its range so far is extreme', () {
      final forming = _c(DateTime.utc(2026, 9, 22, 10), 2400, 2420, 2399, 2418);
      final v = assess(today(), forming: forming);
      expect(v.stressed, isTrue);
      expect(v.candleTime, DateTime.utc(2026, 9, 22, 10));
    });

    test('a stressed candle holds the pause for pause_minutes after it closes, then releases', () {
      final closed = today(lastRange: 30); // the 09:45 candle, closed at 10:00
      expect(assess(closed, at: DateTime.utc(2026, 9, 22, 10, 14)).stressed, isTrue);
      expect(assess(closed, at: DateTime.utc(2026, 9, 22, 10, 15)).stressed, isFalse);
      // 30 minutes keeps it on through the next candle's close as well
      const longer = ChaosParams(pauseMinutes: 30);
      expect(assess(closed, at: DateTime.utc(2026, 9, 22, 10, 29), p: longer).stressed, isTrue);
    });

    test('a candle that closed before the pause window is history', () {
      final closed = [...today(lastRange: 30), _c(DateTime.utc(2026, 9, 22, 10), 2400, 2406, 2400, 2403)];
      final v = assess(closed, at: DateTime.utc(2026, 9, 22, 10, 16));
      expect(v.stressed, isFalse);
    });

    test('with no baseline there is no opinion — it never blocks on a failure', () {
      final none = detector.assess(
        closed15m: today(lastRange: 60),
        baseline: null,
        nowUtc: now,
        params: params,
      );
      expect((none.stressed, none.baselineReady), (false, false));
    });

    test('a slot with too little history is skipped, not guessed at', () {
      final thin = VolatilityBaseline.build(calm().where((c) => c.time.isBefore(base.add(const Duration(days: 5)))).toList(), nowUtc: now);
      final v = assess(today(lastRange: 60), b: thin);
      expect((v.stressed, v.baselineReady), (false, false));
      expect(v.reason, contains('not enough history'));
    });

    test('a live spread 3x its time-of-day median is liquidity stress', () {
      final v = assess(today(), live: 8.0);
      expect(v.stressed, isTrue);
      expect(v.spreadRatio, closeTo(3.2, 1e-9));
      expect(v.reason, allOf(contains('live spread 8.0 pips'), contains('2.5-pip median')));
      expect(assess(today(), live: 7.0).stressed, isFalse);
    });

    test('a spread under 2 pips is never stress, however small the median it is compared with', () {
      final tiny = VolatilityBaseline.build(calm(spread: 0.4), nowUtc: now);
      expect(assess(today(), b: tiny, live: 1.5).stressed, isFalse); // 3.75x, but 1.5 pips
      expect(assess(today(), b: tiny, live: 2.0).stressed, isTrue);
    });

    test('a candle\'s own bar spread is judged too when the history carries one', () {
      final v = assess(today(lastSpread: 9.0));
      expect(v.stressed, isTrue);
      expect(v.reason, contains('candle spread 9.0 pips'));
    });

    test('with no spread history the spread is simply not judged', () {
      final noSpread = VolatilityBaseline.build(calm(spread: 0).map((c) => _c(c.time, c.open, c.high, c.low, c.close)).toList(), nowUtc: now);
      final v = assess(today(), b: noSpread, live: 50);
      expect(v.stressed, isFalse);
      expect(v.spreadRatio, isNull);
    });

    test('a stress episode has a stable key for de-duplicated logging', () {
      final a = assess(today(lastRange: 30), at: DateTime.utc(2026, 9, 22, 10, 1));
      final b = assess(today(lastRange: 30), at: DateTime.utc(2026, 9, 22, 10, 5));
      expect(a.episodeKey, b.episodeKey);
      expect(a.episodeKey, isNot(assess(today()).episodeKey));
    });
  });

  group('atrHeat', () {
    final start = DateTime.utc(2026, 10, 1);

    /// [calm] candles of range [calmRange] followed by [hot] candles of range [hotRange], all closing at 2400.
    List<Candle> series(int calm, double calmRange, {int hot = 0, double hotRange = 0}) => [
          for (var i = 0; i < calm + hot; i++)
            _c(start.add(Duration(minutes: 15 * i)), 2400, 2400 + (i < calm ? calmRange : hotRange) / 2,
                2400 - (i < calm ? calmRange : hotRange) / 2, 2400),
        ];

    test('a steady market is 1.0 - exactly as hot as its own norm', () {
      expect(atrHeat(series(300, 4)), closeTo(1.0, 1e-9));
    });

    test('a market whose ranges just doubled for a few hours is well above 1.2', () {
      expect(atrHeat(series(280, 4, hot: 20, hotRange: 8))!, greaterThan(1.5));
    });

    test('a market that has just gone quiet is below 1', () {
      expect(atrHeat(series(280, 8, hot: 20, hotRange: 4))!, lessThan(1.0));
    });

    test('a mild 10% uptick stays under the 20% line', () {
      expect(atrHeat(series(280, 4, hot: 20, hotRange: 4.4))!, lessThan(1.2));
    });

    test('too little history is no opinion, never "hot"', () {
      expect(atrHeat(series(80, 4)), isNull);
      expect(atrHeat(const []), isNull);
    });

    test('a dead flat feed has no norm to compare with', () {
      expect(atrHeat(series(300, 0)), isNull);
    });

    test('only the last three days are the norm: an old burst is forgotten', () {
      final candles = [...series(60, 20), ...series(300, 4).map((c) => _c(c.time.add(const Duration(days: 30)), c.open, c.high, c.low, c.close))];
      expect(atrHeat(candles)!, closeTo(1.0, 0.05));
    });
  });

  group('recentMoveAtr', () {
    final start = DateTime.utc(2026, 10, 1);

    /// One candle per close, each opening where the last one closed, with a 1-dollar wick on each side.
    List<Candle> walk(List<double> closes) {
      final out = <Candle>[];
      var prev = closes.first;
      for (var i = 0; i < closes.length; i++) {
        final c = closes[i];
        out.add(_c(start.add(Duration(minutes: 15 * i)), prev, (prev > c ? prev : c) + 1, (prev < c ? prev : c) - 1, c));
        prev = c;
      }
      return out;
    }

    List<double> calm(int n) => List.filled(n, 2400.0);

    test('a flat market has moved nothing', () {
      expect(recentMoveAtr(walk(calm(100)))!, closeTo(0, 1e-9));
    });

    test('a fall is negative and a rally is positive, in ATRs', () {
      final fall = recentMoveAtr(walk([...calm(100), for (var i = 1; i <= 8; i++) 2400.0 - 2 * i]))!;
      final rally = recentMoveAtr(walk([...calm(100), for (var i = 1; i <= 8; i++) 2400.0 + 2 * i]))!;
      expect(fall, lessThan(-3));
      expect(rally, greaterThan(3));
      expect(fall, closeTo(-rally, 0.05));
    });

    test('it measures exactly the last 8 candles: close of the last vs close 8 candles earlier', () {
      // only the candle 8 back differs: 2412, then 8 flat candles at 2400
      final closes = [...calm(100), 2412.0, ...List.filled(8, 2400.0)];
      final move = recentMoveAtr(walk(closes), candles: 8)!;
      expect(move, closeTo(-12 / atrSeries(walk(closes)).last!, 1e-9));
      // a window of 9 reaches back to the flat part before the spike, so it sees no move at all
      expect(recentMoveAtr(walk(closes), candles: 9)!, closeTo(0, 1e-9));
    });

    test('too few candles, or a dead feed, is no opinion', () {
      expect(recentMoveAtr(walk(calm(8))), isNull);
      expect(recentMoveAtr(const []), isNull);
      expect(recentMoveAtr([for (var i = 0; i < 40; i++) _c(start.add(Duration(minutes: 15 * i)), 2400, 2400, 2400, 2400)]), isNull);
    });
  });
}
