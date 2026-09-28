import 'dart:math';

import 'package:aureus_ai/models/candle.dart';
import 'package:aureus_ai/models/pivot.dart';
import 'package:aureus_ai/models/trade_setup.dart';
import 'package:aureus_ai/services/breakout_momentum_engine.dart';
import 'package:aureus_ai/services/dxy_filter_service.dart';
import 'package:aureus_ai/services/history_store.dart';
import 'package:aureus_ai/services/monitor_engine.dart';
import 'package:aureus_ai/config/app_config.dart';
import 'package:aureus_ai/services/orb_engine.dart';
import 'package:aureus_ai/services/risk_engine.dart';
import 'package:aureus_ai/services/signal_checker.dart';
import 'package:aureus_ai/services/ta_engine.dart';
import 'package:aureus_ai/services/zone_bounce_engine.dart';
import 'package:aureus_ai/services/tick_stream_service.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Candle _c(DateTime t, double o, double h, double l, double c) =>
    Candle(time: t, open: o, high: h, low: l, close: c, volume: 1);

TradeSetup _setup({
  TradeDirection dir = TradeDirection.buy,
  double entry = 2400,
  double sl = 2398,
  double tp = 2404,
  DateTime? at,
}) =>
    TradeSetup(
      symbol: 'XAUUSD',
      direction: dir,
      timeframeLabel: '15M',
      setupType: SetupType.htfReversal,
      entry: entry,
      stopLoss: sl,
      takeProfit: tp,
      pattern: CandlePattern.bullishEngulfing,
      detectedAt: at ?? DateTime.utc(2026, 9, 14, 10, 0, 20),
    );

/// A textbook bullish HTF Retest on 15M around a $2400.00 zone, laid out so
/// every gate of the protocol is satisfied by exactly one identifiable
/// candle: i6 closes decisively through the zone, i8 is the swing high the
/// MSS later takes out, i11 retests the zone, i12 is the swing low, i17
/// sweeps below it (and below the zone) and closes back above both, and i18
/// is the decisive displacement candle that shifts structure.
List<Candle> _retestSeries({double sweepLow = 2396}) {
  const ohlc = [
    [2394.0, 2395.0, 2393.0, 2394.0],
    [2394.0, 2396.0, 2393.0, 2395.0],
    [2395.0, 2397.0, 2394.0, 2396.0],
    [2396.0, 2398.0, 2395.0, 2397.0],
    [2397.0, 2399.0, 2396.0, 2398.0],
    [2398.0, 2400.0, 2397.0, 2399.0],
    [2399.0, 2406.0, 2398.0, 2405.0], // i6  break through the zone
    [2405.0, 2407.0, 2404.0, 2406.0],
    [2406.0, 2409.0, 2405.0, 2407.0], // i8  swing high / MSS reference
    [2407.0, 2408.0, 2403.0, 2404.0],
    [2404.0, 2405.0, 2401.0, 2402.0],
    [2402.0, 2403.0, 2399.0, 2400.0], // i11 retest back into the zone
    [2400.0, 2401.0, 2397.0, 2398.0], // i12 swing low
    [2398.0, 2399.0, 2397.5, 2398.0],
    [2398.0, 2399.0, 2397.5, 2398.0],
    [2398.0, 2400.0, 2397.5, 2399.0],
    [2399.0, 2401.0, 2398.0, 2400.0],
    [2401.0, 2402.0, 0.0, 2401.0], // i17 liquidity sweep (low injected below)
    [2401.0, 2411.0, 2400.0, 2410.0], // i18 MSS + displacement
  ];
  final start = DateTime.utc(2026, 9, 18, 6);
  return [
    for (var i = 0; i < ohlc.length; i++)
      _c(
        start.add(Duration(minutes: 15 * i)),
        ohlc[i][0],
        ohlc[i][1],
        i == 17 ? sweepLow : ohlc[i][2],
        ohlc[i][3],
      ),
  ];
}

const _retestZones = [
  HtfZone(price: 2400, source: '1H Support'),
  HtfZone(price: 2425, source: '1H Resistance'),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HTF Retest Protocol', () {
    final ta = TaEngine();

    test('fires with the sweep anchor and liquidity target attached', () {
      final trigger = ta.findExecutionTrigger(
        candles: _retestSeries(),
        htfZones: _retestZones,
        htfBias: TradeDirection.buy,
      )!;

      expect(trigger.type, SetupType.htfRetest);
      expect(trigger.pattern, CandlePattern.bullishMomentum);
      // Behind the swept swing low, not the $2400.00 zone boundary.
      expect(trigger.swingAnchor, 2396);
      // The next structure ahead of Entry, not a fixed 1:2 projection.
      expect(trigger.liquidityTarget, 2425);
      expect(trigger.zone.source, contains('Liquidity Sweep (swing + zone)'));
      expect(trigger.zone.source, contains('MSS @ \$2409.00'));
    });

    test('RiskEngine prices SL behind the swing and TP at the target', () {
      final candles = _retestSeries();
      final trigger = ta.findExecutionTrigger(
        candles: candles,
        htfZones: _retestZones,
        htfBias: TradeDirection.buy,
      )!;

      final setup = RiskEngine().buildTradeSetup(
        candles: candles,
        zone: SetupZone(
          type: trigger.type,
          zonePrice: trigger.zone.price,
          candleIndex: trigger.candleIndex,
          swingAnchor: trigger.swingAnchor,
          liquidityTarget: trigger.liquidityTarget,
        ),
        pattern: trigger.pattern,
        timeframeLabel: '15M',
      )!;

      expect(setup.direction, TradeDirection.buy);
      expect(setup.entry, 2410);
      expect(setup.stopLoss, 2395.7); // swept low 2396.00 - $0.30 buffer

      // Take Profit is the fixed AppConfig.riskRewardRatio multiple of the
      // risk on EVERY path since 2026-09-24 ("التيك بروفيت لكل الصفقات
      // 1.8"). This tier used to price TP AT trigger.liquidityTarget
      // (2425) and accept whatever ratio that paid — the target is still
      // computed and passed in above, it is simply no longer what prices
      // the trade.
      expect(trigger.liquidityTarget, 2425);
      expect(setup.riskRewardRatio, closeTo(AppConfig.riskRewardRatio, 0.01));
      expect(setup.takeProfit, closeTo(2410 + AppConfig.riskRewardRatio * (2410 - 2395.7), 0.01));
    });

    test('a zone-only sweep still qualifies, and anchors the SL to itself', () {
      // i17 no longer reaches the i12 swing low, but still wicks through the
      // zone and closes back above it.
      final trigger = ta.findExecutionTrigger(
        candles: _retestSeries(sweepLow: 2398),
        htfZones: _retestZones,
        htfBias: TradeDirection.buy,
      )!;

      expect(trigger.type, SetupType.htfRetest);
      expect(trigger.zone.source, contains('Liquidity Sweep (zone)'));
      expect(trigger.swingAnchor, 2398);
    });

    test('no trade when no liquidity was taken at all', () {
      // i17 stays above both the swing low and the zone — nothing swept.
      final trigger = ta.findExecutionTrigger(
        candles: _retestSeries(sweepLow: 2401),
        htfZones: _retestZones,
        htfBias: TradeDirection.buy,
      );
      expect(trigger?.type, isNot(SetupType.htfRetest));
    });

    test('no trade against the HTF bias, or without one', () {
      for (final bias in [TradeDirection.sell, null]) {
        final trigger = ta.findExecutionTrigger(
          candles: _retestSeries(),
          htfZones: _retestZones,
          htfBias: bias,
        );
        expect(trigger?.type, isNot(SetupType.htfRetest), reason: 'bias: $bias');
      }
    });
  });

  // Ranging Market Module — Zone Bounce Protocol (2026-09-25). The tier
  // exists because the Top-Down protocol structurally cannot produce a
  // bounce off a level that HOLDS; these pin both that it fires on the
  // real shape and that it refuses everything it is meant to refuse.
  group('ZoneBounceEngine', () {
    final engine = ZoneBounceEngine();
    final base = DateTime.utc(2026, 9, 25, 8);

    const level = 2400.0;
    final support = [const HtfZone(price: level, source: '1H Support')];

    /// Quiet candles well ABOVE the level, so nothing in the lookback ever
    /// counts as a break of it and the range/ATR stay small and stable.
    List<Candle> approach({int count = 24}) => [
          for (var i = 0; i < count; i++)
            _c(base.add(Duration(minutes: 15 * i)), 2406, 2408, 2404, 2406),
        ];

    /// Appends one candle to a clean approach and runs the engine on it.
    ZoneBounceTrigger? runWith(
      List<double> ohlc, {
      List<HtfZone>? zones,
      TradeDirection? bias,
      List<Candle>? prefix,
    }) {
      final candles = [
        ...(prefix ?? approach()),
        _c(base.add(const Duration(hours: 12)), ohlc[0], ohlc[1], ohlc[2], ohlc[3]),
      ];
      return engine.findTrigger(
        candles: candles,
        zones: zones ?? support,
        htfBias: bias,
      );
    }

    test('fires on a pinbar rejection off a support that holds', () {
      // Wicks down THROUGH the level, closes back well above it.
      final t = runWith([2403, 2404.5, 2398.5, 2404.2])!;
      expect(t.direction, TradeDirection.buy);
      expect(t.pattern, CandlePattern.bullishPinbar);
      expect(t.rejectionExtreme, 2398.5);
      expect(t.zone.price, level);
    });

    test('stands down entirely when a clear HTF bias exists', () {
      // Identical candle to the passing case — only the bias differs, so
      // the ranging gate is provably the only reason this is refused.
      expect(runWith([2403, 2404.5, 2398.5, 2404.2], bias: TradeDirection.buy), isNull);
      expect(runWith([2403, 2404.5, 2398.5, 2404.2], bias: TradeDirection.sell), isNull);
    });

    test('refuses a breakout — a close through the level is not a bounce', () {
      // Same rejection wick, but the candle CLOSES below the level.
      expect(runWith([2404, 2405, 2396, 2397]), isNull);
    });

    test('refuses a bounce off a level that was already broken recently', () {
      // A candle inside the lookback closes a full interestZoneBufferDollars
      // below the level: this is a BROKEN level being retested, which is the
      // Top-Down protocol's territory, not a holding range boundary.
      final broken = approach();
      broken[broken.length - 3] = _c(
        broken[broken.length - 3].time,
        2400,
        2401,
        2393,
        level - AppConfig.interestZoneBufferDollars - 1,
      );
      expect(runWith([2403, 2404.5, 2398.5, 2404.2], prefix: broken), isNull);
    });

    test('refuses a long-legged doji at the level', () {
      // Body 0.02 on a 4.3 range: the wick reaches deep into the level, but
      // indecision is not a rejection, so the wick test must not rescue it.
      expect(runWith([2404, 2404.2, 2399.9, 2404.02]), isNull);
    });

    test('refuses a candle whose rejection wick is too small a share of it', () {
      // Touches the level and closes above it, but the lower wick is only
      // ~36% of the candle's range — below zoneBounceMinWickRatio.
      expect(runWith([2405, 2405, 2398.5, 2401]), isNull);
    });

    test('refuses a candle whose wick never reaches the level', () {
      // A textbook pinbar shape, but floating $4 above the zone.
      expect(runWith([2409, 2410, 2404.5, 2409]), isNull);
    });

    // Multi-Zone Evaluation fix (2026-09-25), reproduced with the exact
    // numbers observed live: price $4286.13, a 15M Support $1.66 away and a
    // 1H Support $2.33 away. The handicap (2.33 - 1.00 < 1.66) hands the
    // single-zone ranking to the 1H level, so the closer one price was
    // actually reacting at was never examined at all.
    test('findNearestZones ranks by true distance, unlike findNearestZone', () {
      final ta = TaEngine();
      const price = 4286.13;
      final zones = [
        const HtfZone(price: 4284.47, source: '15M Support'),
        const HtfZone(price: 4288.46, source: '1H Support'),
      ];
      expect(ta.findNearestZone(zones, price)?.price, 4288.46,
          reason: 'the handicap lets the further 1H zone win');
      expect(ta.findNearestZones(zones, price, count: 2).first.price, 4284.47,
          reason: 'true distance puts the genuinely closer 15M zone first');
    });

    test('evaluates a zone that loses the handicapped ranking', () {
      // The 1H zone wins findNearestZone (4.5 - 1.0 < 4.0) but no bounce can
      // form at it; the 15M level is the one price rejected off. Under
      // single-zone evaluation this cycle produced nothing at all.
      final zones = [
        const HtfZone(price: level, source: '15M Support'),
        const HtfZone(price: 2408.5, source: '1H Resistance'),
      ];
      expect(TaEngine().findNearestZone(zones, 2404.2)?.price, 2408.5);

      final t = runWith([2403, 2404.5, 2398.5, 2404.2], zones: zones)!;
      expect(t.zone.price, level);
    });

    // Adaptive Target rule (2026-09-25). Fixed geometry: entry 2404.2, wick
    // 2398.5, ATR 2.0 => SL 2397.5, risk 6.70, so 1.0R = 2410.90 and the
    // fixed 1:1.8 target = 2416.26. Only the boundary moves between cases.
    group('Adaptive Take Profit', () {
      const entry = 2404.2;
      late double sl, fixedTarget;

      ZoneBounceTrigger triggerWithBoundary(double boundary) {
        final zones = [
          const HtfZone(price: level, source: '1H Support'),
          HtfZone(price: boundary, source: '1H Resistance'), // the far side
        ];
        final t = runWith([2403, 2404.5, 2398.5, 2404.2], zones: zones)!;
        sl = engine.stopLossFor(t, atr: 2.0)!;
        fixedTarget = entry + AppConfig.riskRewardRatio * (entry - sl);
        expect(t.rangeBoundary, boundary);
        return t;
      }

      test('SL sits beyond the rejection wick', () {
        final t = triggerWithBoundary(2412.0);
        expect(sl, lessThan(t.rejectionExtreme));
      });

      test('a boundary >= 1.0R away clips Take Profit to it', () {
        final t = triggerWithBoundary(2412.0); // 1.16R, nearer than 1.8R
        expect(fixedTarget, greaterThan(2412.0));
        expect(engine.takeProfitFor(t, entry: entry, stopLoss: sl), 2412.0);
      });

      test('a boundary of exactly 1.0R is already far enough to clip', () {
        final t = triggerWithBoundary(entry + (entry - 2397.5)); // exactly 1.0R
        expect(engine.takeProfitFor(t, entry: entry, stopLoss: sl), closeTo(2410.9, 0.001));
      });

      test('a boundary < 1.0R away is ignored — TP stays at the full 1:1.8, setup not cancelled', () {
        final t = triggerWithBoundary(2409.0); // 0.72R
        final tp = engine.takeProfitFor(t, entry: entry, stopLoss: sl);
        expect(tp, closeTo(fixedTarget, 0.001));
        expect(tp, greaterThan(2409.0), reason: 'deliberately NOT clipped to the near boundary');
      });

      test('a boundary beyond the fixed target never EXTENDS it', () {
        final t = triggerWithBoundary(2430.0); // ~3.8R
        expect(engine.takeProfitFor(t, entry: entry, stopLoss: sl), closeTo(fixedTarget, 0.001));
      });
    });

    // Direction comes from where price ARRIVED, not just where this candle
    // closed. Found in the 72-hour backtest: a breakdown candle shaped like a
    // bearish Engulfing used to pass as a "sell bounce" and was only caught,
    // incidentally, by the broken-level lookback. Prior closes here sit inside
    // the 4-dollar lookback band so that safety net cannot be what refuses it.
    test('a breakdown through support is a break, not a sell bounce', () {
      final prefix = [
        for (var i = 0; i < 23; i++) _c(base.add(Duration(minutes: 15 * i)), 2401, 2402.5, 2399.5, 2401),
        _c(base.add(const Duration(minutes: 15 * 23)), 2400.5, 2402, 2400, 2401.5), // bullish
      ];
      final candles = [
        ...prefix,
        // Opens above the level, engulfs the bullish candle, closes BELOW 2400.
        _c(base.add(const Duration(hours: 6)), 2401.5, 2402, 2395, 2396),
      ];
      expect(engine.findTrigger(candles: candles, zones: support, htfBias: null), isNull);
      final d = engine.diagnose(candles: candles, zones: support, htfBias: null);
      expect(d.reject, ZoneBounceReject.closedThrough);
    });

    test('diagnose reports the gate that refused, from the same logic as findTrigger', () {
      final base15 = approach();
      List<Candle> withLast(List<double> o) =>
          [...base15, _c(base.add(const Duration(hours: 12)), o[0], o[1], o[2], o[3])];

      expect(engine.diagnose(candles: withLast([2403, 2404.5, 2398.5, 2404.2]), zones: support, htfBias: TradeDirection.buy).reject,
          ZoneBounceReject.biasPresent);
      expect(engine.diagnose(candles: withLast([2409, 2410, 2404.5, 2409]), zones: support, htfBias: null).reject,
          ZoneBounceReject.noZoneTouched);
      expect(engine.diagnose(candles: withLast([2404, 2404.2, 2399.9, 2404.02]), zones: support, htfBias: null).reject,
          ZoneBounceReject.doji);
      expect(engine.diagnose(candles: withLast([2405, 2405, 2398.5, 2401]), zones: support, htfBias: null).reject,
          ZoneBounceReject.noRejectionPattern);
      expect(engine.diagnose(candles: withLast([2403, 2404.5, 2398.5, 2404.2]), zones: support, htfBias: null).trigger,
          isNotNull);
    });

    test('leaves Take Profit at the full ratio when the range has room', () {
      final t = runWith([2403, 2404.5, 2398.5, 2404.2])!; // no opposing zone above
      const entry = 2404.2;
      final sl = engine.stopLossFor(t, atr: 2.0)!;
      expect(
        engine.takeProfitFor(t, entry: entry, stopLoss: sl),
        closeTo(entry + AppConfig.riskRewardRatio * (entry - sl), 0.001),
      );
    });

    test('mirrors for a resistance: sells the rejection off the level', () {
      final zones = [const HtfZone(price: 2408.0, source: '1H Resistance')];
      final prefix = [
        for (var i = 0; i < 24; i++)
          _c(base.add(Duration(minutes: 15 * i)), 2402, 2404, 2400, 2402),
      ];
      final t = runWith([2405, 2409.5, 2403.5, 2403.8], zones: zones, prefix: prefix)!;
      expect(t.direction, TradeDirection.sell);
      expect(t.rejectionExtreme, 2409.5);
    });
  });

  group('OrbEngine', () {
    final orb = OrbEngine();
    // London opens at AppConfig.londonSessionStartUtc (07:00 UTC).
    final sessionStart = DateTime.utc(2026, 9, 18, 7);

    List<Candle> m5(List<List<double>> ohlc, {DateTime? start}) {
      final t0 = start ?? sessionStart;
      return [
        for (var i = 0; i < ohlc.length; i++)
          _c(t0.add(Duration(minutes: 5 * i)), ohlc[i][0], ohlc[i][1], ohlc[i][2], ohlc[i][3]),
      ];
    }

    test('computeRange is null until the opening-range window has closed', () {
      final candles = m5([
        for (var i = 0; i < 6; i++) [2400.0, 2401.0, 2399.0, 2400.0],
      ]);
      // Narrowed to a 15-minute window 2026-09-24 (AppConfig.orbRangeMinutes),
      // so it closes at 07:15 — 07:14 hasn't reached it yet.
      final tooEarly = orb.computeRange(candles, OrbSession.london, DateTime.utc(2026, 9, 18, 7, 14));
      expect(tooEarly, isNull);

      final ready = orb.computeRange(candles, OrbSession.london, DateTime.utc(2026, 9, 18, 7, 15));
      expect(ready, isNotNull);
    });

    test('computeRange is the high/low of exactly the opening-range candles', () {
      final candles = m5([
        [2400.0, 2402.0, 2399.0, 2401.0],
        [2401.0, 2405.0, 2400.0, 2404.0],
        [2404.0, 2406.0, 2398.0, 2400.0], // range high 2406 / low 2398
        // After the 15-minute window: must NOT affect the range, even
        // though these candles are wider on both sides.
        [2400.0, 2412.0, 2390.0, 2401.0],
        [2401.0, 2404.0, 2400.0, 2402.0],
        [2402.0, 2403.0, 2401.0, 2402.0],
        [2402.0, 2420.0, 2380.0, 2410.0],
      ]);
      final range = orb.computeRange(candles, OrbSession.london, DateTime.utc(2026, 9, 18, 8))!;
      expect(range.high, 2406.0);
      expect(range.low, 2398.0);
      expect(range.key, 'london#2026-09-18');
    });

    test('computeRange is null on a data gap inside the opening window', () {
      // Only 2 candles cover the 15-minute window instead of the 3 it needs.
      final candles = m5([
        for (var i = 0; i < 2; i++) [2400.0, 2401.0, 2399.0, 2400.0],
      ]);
      expect(orb.computeRange(candles, OrbSession.london, DateTime.utc(2026, 9, 18, 8)), isNull);
    });

    final range = OrbRange(
      session: OrbSession.london,
      rangeStart: sessionStart,
      rangeEnd: sessionStart.add(const Duration(minutes: 15)),
      high: 2405.0,
      low: 2398.0,
    );

    test('findTrigger ignores a wick beyond the range with no close beyond it', () {
      final after = m5(
        [
          [2401.0, 2408.0, 2400.0, 2403.0], // wicks above range high, closes back inside
        ],
        start: range.rangeEnd,
      );
      expect(orb.findTrigger(after, range), isNull);
    });

    test('findTrigger does not fire on the raw breakout alone — a retest is mandatory', () {
      final after = m5(
        [
          [2403.0, 2404.0, 2402.0, 2403.5], // still inside
          [2403.5, 2407.0, 2403.0, 2406.0], // CLOSED above range.high (2405) -> breakout, no retest yet
        ],
        start: range.rangeEnd,
      );
      expect(orb.findTrigger(after, range), isNull);
    });

    test('findTrigger waits for the pullback and resumption before firing', () {
      final after = m5(
        [
          [2403.5, 2407.0, 2403.0, 2406.0], // breakout candle, closes above 2405
          [2406.0, 2406.5, 2404.0, 2404.5], // pulls back but doesn't touch 2405 yet
          [2404.5, 2405.2, 2404.9, 2405.0], // touches boundary, closes back INSIDE — not yet
          [2405.0, 2409.0, 2404.8, 2408.0], // touches boundary again, closes ABOVE — resumption
        ],
        start: range.rangeEnd,
      );
      final trigger = orb.findTrigger(after, range)!;
      expect(trigger.direction, TradeDirection.buy);
      expect(trigger.entryCandle.close, 2408.0);
    });

    test('findTrigger invalidates on a close through the far side', () {
      final after = m5(
        [
          [2403.5, 2407.0, 2403.0, 2406.0], // breakout above 2405
          [2406.0, 2406.5, 2396.0, 2397.0], // closes below range.low (2398) — invalidated
          [2397.0, 2410.0, 2396.0, 2409.0], // would otherwise look like a resumption
        ],
        start: range.rangeEnd,
      );
      expect(orb.findTrigger(after, range), isNull);
    });

    // 2-hour validity window (AppConfig.orbMaxHoursAfterRange, 2026-09-24).
    // The reviewed session fired a New York ORB entry more than six hours
    // after its range closed; these pin that shut.
    test('deadline is orbMaxHoursAfterRange past the end of the range window', () {
      expect(
        orb.deadline(range),
        range.rangeEnd.add(const Duration(hours: AppConfig.orbMaxHoursAfterRange)),
      );
    });

    test('findTrigger ignores a breakout + retest that completes after the deadline', () {
      // Same candle shapes as the passing resumption case above — only the
      // START TIME differs, so the pattern itself is known-good and the
      // deadline is provably the only reason this one is rejected.
      final shapes = [
        [2403.5, 2407.0, 2403.0, 2406.0], // breakout, closes above 2405
        [2406.0, 2406.5, 2404.0, 2404.5],
        [2404.5, 2405.2, 2404.9, 2405.0],
        [2405.0, 2409.0, 2404.8, 2408.0], // retest + resumption
      ];
      expect(orb.findTrigger(m5(shapes, start: range.rangeEnd), range), isNotNull);

      final tooLate = m5(shapes, start: orb.deadline(range));
      expect(orb.findTrigger(tooLate, range), isNull);
    });

    // Regression, 2026-09-25 (found live): findTrigger is STATELESS and
    // bounds only when the pattern may occur — it happily re-derives the
    // same valid in-window trigger on every later cycle, forever. The real
    // incident: a New York trigger completing by 14:15 UTC fired as an
    // entry at 22:15 UTC, 8 hours late. The wall-clock gate that stops it
    // lives in SignalChecker._evaluateOrbTrigger; this pins the engine
    // behaviour that makes that gate load-bearing, so nobody later "fixes"
    // the gate away believing findTrigger already covers it.
    test('findTrigger still returns an in-window trigger long after the deadline', () {
      final after = m5([
        [2403.5, 2407.0, 2403.0, 2406.0], // breakout, inside the window
        [2406.0, 2406.5, 2404.0, 2404.5],
        [2404.5, 2405.2, 2404.9, 2405.0],
        [2405.0, 2409.0, 2404.8, 2408.0], // retest + resumption, inside
      ], start: range.rangeEnd);

      // The pattern is in-window, so the engine keeps reporting it — the
      // caller, not the engine, is what must refuse to act on it now.
      expect(orb.findTrigger(after, range), isNotNull);
      expect(orb.deadline(range).isBefore(range.rangeEnd.add(const Duration(hours: 8))), isTrue);
    });

    test('findTrigger rejects a retest that lands just past the deadline', () {
      // Breakout comfortably inside the window, resumption 5 minutes after
      // it closes: BOTH halves have to complete in time, not just the break.
      final deadline = orb.deadline(range);
      final after = [
        ...m5([
          [2403.5, 2407.0, 2403.0, 2406.0], // breakout, well inside the window
        ], start: range.rangeEnd),
        ...m5([
          [2405.0, 2409.0, 2404.8, 2408.0], // retest + resumption, 5m too late
        ], start: deadline),
      ];
      expect(orb.findTrigger(after, range), isNull);
    });
  });

  group('DxyFilterService', () {
    test('bypasses (allows) when the filter is disabled', () async {
      dotenv.testLoad(fileInput: 'USE_MOCK_DATA=false\nUSE_DXY_FILTER=false');
      final dxy = DxyFilterService();
      expect(await dxy.confirms(TradeDirection.buy), isTrue);
      expect(await dxy.confirms(TradeDirection.sell), isTrue);
    });

    test('bypasses (allows) under mock data even when enabled', () async {
      dotenv.testLoad(fileInput: 'USE_MOCK_DATA=true\nUSE_DXY_FILTER=true');
      final dxy = DxyFilterService();
      expect(await dxy.confirms(TradeDirection.buy), isTrue);
      expect(await dxy.confirms(TradeDirection.sell), isTrue);
    });
  });

  group('TaEngine.averageTrueRange', () {
    final ta = TaEngine();

    List<Candle> quietSeries(int count) {
      final start = DateTime.utc(2026, 9, 18, 0);
      return [
        for (var i = 0; i < count; i++) _c(start.add(Duration(minutes: 5 * i)), 100, 101, 99, 100),
      ];
    }

    test('null when there are not enough candles', () {
      expect(ta.averageTrueRange(quietSeries(10), period: 14), isNull);
    });

    test('settles to the constant true range of a quiet series', () {
      expect(ta.averageTrueRange(quietSeries(20), period: 14), closeTo(2.0, 0.0001));
    });
  });

  group('BreakoutMomentumEngine', () {
    final engine = BreakoutMomentumEngine();

    List<Candle> quietM5(int count, {DateTime? start}) {
      final t0 = start ?? DateTime.utc(2026, 9, 18, 0);
      return [
        for (var i = 0; i < count; i++) _c(t0.add(Duration(minutes: 5 * i)), 100, 101, 99, 100),
      ];
    }

    group('level identification', () {
      test('previousSessionLevels reads the most recently completed session window', () {
        // Day 1's Asian session (00:00-09:00 UTC) on 15M candles.
        final day1 = DateTime.utc(2026, 9, 18, 0);
        final candles = [
          for (var i = 0; i < 36; i++) // 9 hours of 15M candles
            _c(day1.add(Duration(minutes: 15 * i)), 2400, 2400 + i * 0.1, 2399 - i * 0.05, 2400),
        ];
        // "Now" is Day 2, 05:00 — before Day 2's own Asian session has
        // ended, so this must resolve to Day 1's (fully elapsed) session.
        final nowUtc = DateTime.utc(2026, 9, 19, 5);
        final levels = engine.previousSessionLevels(candles, nowUtc);
        final asianHigh = levels.firstWhere((l) => l.label == 'Asian Session High');
        final asianLow = levels.firstWhere((l) => l.label == 'Asian Session Low');
        expect(asianHigh.price, candles.map((c) => c.high).reduce(max));
        expect(asianLow.price, candles.map((c) => c.low).reduce(min));
      });

      test('previousDayLevels reads the prior UTC calendar day from H1 candles', () {
        final day1 = DateTime.utc(2026, 9, 18, 0);
        final candles = [
          for (var i = 0; i < 24; i++)
            _c(day1.add(Duration(hours: i)), 2400, 2410 + i.toDouble(), 2390 - i.toDouble(), 2400),
        ];
        final levels = engine.previousDayLevels(candles, DateTime.utc(2026, 9, 19, 10));
        expect(levels.firstWhere((l) => l.kind == BreakoutLevelKind.previousDayHigh).price, 2433.0);
        expect(levels.firstWhere((l) => l.kind == BreakoutLevelKind.previousDayLow).price, 2367.0);
      });

      test('openingRangeLevels uses the default 00:00-01:00 UTC window', () {
        final day1 = DateTime.utc(2026, 9, 18, 0);
        final candles = [
          for (var i = 0; i < 4; i++)
            _c(day1.add(Duration(minutes: 15 * i)), 2400, 2405 + i.toDouble(), 2395 - i.toDouble(), 2400),
          // After the window — must not affect the range.
          _c(day1.add(const Duration(hours: 2)), 2400, 2500, 2300, 2400),
        ];
        final levels = engine.openingRangeLevels(candles, DateTime.utc(2026, 9, 18, 12));
        expect(levels.firstWhere((l) => l.kind == BreakoutLevelKind.openingRangeHigh).price, 2408.0);
        expect(levels.firstWhere((l) => l.kind == BreakoutLevelKind.openingRangeLow).price, 2392.0);
      });

      test('htfLevels keeps only Support/Resistance zones, classified correctly', () {
        const zones = [
          HtfZone(price: 2400, source: '1H Resistance'),
          HtfZone(price: 2380, source: '4H Support'),
          HtfZone(price: 2390, source: '15M Trendline (ascending)'),
        ];
        final levels = engine.htfLevels(zones);
        expect(levels.length, 2);
        expect(levels.firstWhere((l) => l.price == 2400).kind, BreakoutLevelKind.htfResistance);
        expect(levels.firstWhere((l) => l.price == 2380).kind, BreakoutLevelKind.htfSupport);
      });
    });

    group('swingLevels + prioritize', () {
      test('swingLevels keeps confirmed 15M pivots on both sides', () {
        final t0 = DateTime.utc(2026, 9, 22, 0);
        // A clear spike high at index 5 and a clear spike low at index 12;
        // findPivots needs `lookback` candles closed on BOTH sides, so
        // neither edge of the series can produce one.
        final candles = [
          for (var i = 0; i < 18; i++) _c(t0.add(Duration(minutes: 15 * i)), 100, 101, 99, 100),
        ];
        candles[5] = _c(candles[5].time, 100, 110, 99.5, 100);
        candles[12] = _c(candles[12].time, 100, 100.5, 90, 100);

        final levels = engine.swingLevels(candles);
        expect(levels.any((l) => l.kind == BreakoutLevelKind.swingHigh && l.price == 110), isTrue);
        expect(levels.any((l) => l.kind == BreakoutLevelKind.swingLow && l.price == 90), isTrue);
      });

      test('prioritize orders by level importance and drops same-price duplicates', () {
        const levels = [
          BreakoutLevel(kind: BreakoutLevelKind.openingRangeHigh, price: 2400.2, label: 'OR High'),
          BreakoutLevel(kind: BreakoutLevelKind.htfResistance, price: 2400.0, label: '1H Resistance'),
          BreakoutLevel(kind: BreakoutLevelKind.previousDayLow, price: 2380.0, label: 'PDL'),
        ];
        final ordered = engine.prioritize(levels);
        // The HTF level outranks the Opening Range one AND is within the
        // dedupe window of it, so the weaker duplicate is gone entirely.
        expect(ordered.first.kind, BreakoutLevelKind.htfResistance);
        expect(ordered.any((l) => l.kind == BreakoutLevelKind.openingRangeHigh), isFalse);
        // A genuinely different level (and direction) survives.
        expect(ordered.any((l) => l.kind == BreakoutLevelKind.previousDayLow), isTrue);
      });
    });

    group('isStrongBreakoutCandle', () {
      const level = BreakoutLevel(kind: BreakoutLevelKind.htfResistance, price: 105, label: 'Test Resistance');
      final t0 = DateTime.utc(2026, 9, 22, 0);
      Candle c(double o, double h, double l, double close) => _c(t0, o, h, l, close);

      test('accepts a whole-candle break with an expanded range and a close at the extreme', () {
        expect(engine.isStrongBreakoutCandle(c(105.3, 107.55, 105.05, 106.85), level, 2.4, 2.0), isTrue);
      });

      test('rejects a candle whose LOW still straddles the level (Whole-Candle Break)', () {
        expect(engine.isStrongBreakoutCandle(c(104.0, 107.55, 103.5, 106.85), level, 2.4, 2.0), isFalse);
      });

      test('rejects a body too small, and an over-extended (exhaustion) body', () {
        // body 0.15 vs ATR 2.4 -> 0.06, far under the 0.6 floor.
        expect(engine.isStrongBreakoutCandle(c(106.7, 107.55, 105.05, 106.85), level, 2.4, 2.0), isFalse);
        // body 7.8 vs ATR 2.4 -> 3.25, over the 2.5 exhaustion ceiling.
        expect(engine.isStrongBreakoutCandle(c(105.1, 113.0, 105.05, 112.9), level, 2.4, 2.0), isFalse);
      });

      test('rejects a close that does not sit near the breakout-side extreme', () {
        // Close location (105.6-105.05)/2.5 = 0.22, under the 0.70 floor.
        expect(engine.isStrongBreakoutCandle(c(105.1, 107.55, 105.05, 105.6), level, 2.4, 2.0), isFalse);
      });

      test('Momentum Confirmation: the same candle passes or fails purely on range expansion', () {
        final candle = c(105.1, 107.0, 105.05, 106.9); // range 1.95, body 1.8, close at the top
        // Average range 2.0 -> expansion 0.98, under the 1.2 floor.
        expect(engine.isStrongBreakoutCandle(candle, level, 2.0, 2.0), isFalse);
        // Average range 1.5 -> expansion 1.30, clears it.
        expect(engine.isStrongBreakoutCandle(candle, level, 2.0, 1.5), isTrue);
      });
    });

    group('findTrigger', () {
      const level = BreakoutLevel(kind: BreakoutLevelKind.htfResistance, price: 105, label: 'Test Resistance');

      // 20 quiet candles settle ATR(14) and the average range at exactly
      // 2.0 before the test candles are appended — but the returned ATR
      // reflects the FULL series including those candles' own true ranges
      // (standard "current bar" ATR behavior), so a wide test candle pulls
      // the reported ATR up from there.
      List<Candle> series(List<List<double>> appended) {
        final candles = quietM5(20);
        for (final bar in appended) {
          candles.add(_c(candles.last.time.add(const Duration(minutes: 5)), bar[0], bar[1], bar[2], bar[3]));
        }
        return candles;
      }

      // Clears every gate: whole candle above 105, body 1.55 (~0.65 ATR),
      // close location 0.72, range 2.5 (1.25x the 2.0 average), and a close
      // 1.85 above the level — just inside the 0.8 ATR chase limit.
      const strongBreakout = [105.3, 107.55, 105.05, 106.85];

      test('immediate mode fires on a strong, close-to-the-level breakout candle', () {
        final trigger = engine.findTrigger(series([strongBreakout]), [level], requireRetest: false);
        expect(trigger, isNotNull);
        expect(trigger!.direction, TradeDirection.buy);
        expect(trigger.retestConfirmed, isFalse);
        expect(trigger.rangeExpansion, greaterThanOrEqualTo(1.2));
        expect(trigger.entryDistanceAtr, lessThanOrEqualTo(0.8));
      });

      test('immediate mode ignores a wick beyond the level with no confirmed close beyond it', () {
        final trigger = engine.findTrigger(series([
          [101, 106, 100.8, 104.5]
        ]), [level], requireRetest: false);
        expect(trigger, isNull);
      });

      test("Don't Chase: the same candle is rejected once the level sits far behind it", () {
        // Identical candle, level moved down to 103 -> the close is now
        // 3.85 past it, well beyond 0.8 x ATR.
        const farLevel = BreakoutLevel(kind: BreakoutLevelKind.htfResistance, price: 103, label: 'Far Resistance');
        final trigger = engine.findTrigger(series([strongBreakout]), [farLevel], requireRetest: false);
        expect(trigger, isNull);
      });

      test('retest mode does NOT fire on the raw breakout candle alone', () {
        final trigger = engine.findTrigger(series([strongBreakout]), [level], requireRetest: true);
        expect(trigger, isNull);
      });

      test('retest mode fires after price returns to the level and resumes', () {
        final trigger = engine.findTrigger(
          series([
            strongBreakout,
            [106.8, 106.9, 105.2, 105.6], // pullback that touches the level and holds it
            [105.6, 106.6, 105.5, 106.5], // resumption close beyond the level
          ]),
          [level],
          requireRetest: true,
        );
        expect(trigger, isNotNull);
        expect(trigger!.retestConfirmed, isTrue);
        expect(trigger.breakoutCandle.close, 106.85);
        expect(trigger.candle.close, 106.5);
      });

      test('Failed-Breakout Protection: a close back through the level kills the setup', () {
        final trigger = engine.findTrigger(
          series([
            strongBreakout,
            [106.8, 106.9, 104.0, 104.5], // CLOSED back under the level
            [105.6, 106.6, 105.5, 106.5], // later reclaim must not rehabilitate it
          ]),
          [level],
          requireRetest: true,
        );
        expect(trigger, isNull);
      });

      test('retest mode needs an actual return to the level, not just a pause above it', () {
        final trigger = engine.findTrigger(
          series([
            strongBreakout,
            [106.85, 107.0, 106.0, 106.5], // never comes back near 105
            [105.9, 106.3, 105.8, 106.2],
          ]),
          [level],
          requireRetest: true,
        );
        expect(trigger, isNull);
      });

      test('a rejected breakout produces no trade while the reversal option is off', () {
        dotenv.testLoad(fileInput: 'BREAKOUT_FAILED_REVERSAL=false');
        final trigger = engine.findTrigger(
          series([
            strongBreakout,
            [106.8, 106.9, 104.0, 104.2], // CLOSED back under the level: the break failed
            [104.2, 104.3, 103.2, 103.4], // confirmation extending the rejection
          ]),
          [level],
          requireRetest: true,
        );
        expect(trigger, isNull);
      });
    });

    group('Failed-Breakout Reversal', () {
      const level = BreakoutLevel(kind: BreakoutLevelKind.htfResistance, price: 105, label: 'Test Resistance');
      const strongBreakout = [105.3, 107.55, 105.05, 106.85];

      List<Candle> series(List<List<double>> appended) {
        final candles = quietM5(20);
        for (final bar in appended) {
          candles.add(_c(candles.last.time.add(const Duration(minutes: 5)), bar[0], bar[1], bar[2], bar[3]));
        }
        return candles;
      }

      setUp(() => dotenv.testLoad(fileInput: 'BREAKOUT_FAILED_REVERSAL=true'));
      tearDown(() => dotenv.testLoad(fileInput: 'USE_MOCK_DATA=true'));

      test('fires the OPPOSITE direction once a confirmation candle extends the rejection', () {
        final trigger = engine.findTrigger(
          series([
            strongBreakout, // bullish break above 105
            [106.8, 106.9, 104.6, 104.8], // failure: CLOSED back under 105
            [104.8, 104.9, 104.3, 104.45], // confirmation: extends the rejection
          ]),
          [level],
          requireRetest: true,
        );
        expect(trigger, isNotNull);
        expect(trigger!.isFailedReversal, isTrue);
        // The level's own breakout direction was BUY — the trap trades SELL.
        expect(level.kind.breakoutDirection, TradeDirection.buy);
        expect(trigger.direction, TradeDirection.sell);
        // Stop anchors to the trap's own extreme (the breakout candle's high).
        expect(trigger.fakeoutExtreme, 107.55);
        expect(trigger.candle.close, 104.45);
        // ...and the entry is close enough to that anchor to be tradeable.
        expect(trigger.trapDistanceAtr, lessThanOrEqualTo(1.5));
      });

      test('rejects an entry that has run too far from the trap extreme its stop hangs off', () {
        // The exact shape that cost 198 pips live on 2026-09-23: the entry
        // sat a fraction of an ATR from the LEVEL (so the normal don't-chase
        // gate was happy) but ~1.8 ATR from the trap extreme, pricing the
        // trade at a risk the setup never justified.
        final trigger = engine.findTrigger(
          series([
            strongBreakout,
            [106.8, 106.9, 104.0, 104.2],
            [104.2, 104.3, 103.2, 103.4], // 4.15 away from the 107.55 trap high
          ]),
          [level],
          requireRetest: true,
        );
        expect(trigger, isNull);
      });

      test('waits for the confirmation candle — a bare failure is not an entry', () {
        // The failure candle IS the last candle ("ما ياخدو الا ليكون في
        // شمعة تاكيدية بتاكد فشل الاختراق").
        final trigger = engine.findTrigger(
          series([
            strongBreakout,
            [106.8, 106.9, 104.0, 104.2],
          ]),
          [level],
          requireRetest: true,
        );
        expect(trigger, isNull);
      });

      test('rejects a confirmation candle that stalls instead of extending the rejection', () {
        final trigger = engine.findTrigger(
          series([
            strongBreakout,
            [106.8, 106.9, 104.0, 104.2],
            [104.2, 104.9, 104.1, 104.8], // closed back UP, above the failure close
          ]),
          [level],
          requireRetest: true,
        );
        expect(trigger, isNull);
      });

      test('the Asian session is a separate opt-in window, off by default', () {
        dotenv.testLoad(fileInput: 'BREAKOUT_SESSION_FILTER=true');
        expect(AppConfig.breakoutAsianSessionEnabled, isFalse);
        // Defaults line up with the codebase-wide Asian window so "the
        // Asian session" means one thing everywhere.
        expect(AppConfig.breakoutAsianStartUtcMinutes, AppConfig.asianSessionStartUtc * 60);
        expect(AppConfig.breakoutAsianEndUtcMinutes, AppConfig.asianSessionEndUtc * 60);

        dotenv.testLoad(fileInput: 'BREAKOUT_ASIAN_SESSION=true\nBREAKOUT_ASIAN_START_UTC=01:30');
        expect(AppConfig.breakoutAsianSessionEnabled, isTrue);
        expect(AppConfig.breakoutAsianStartUtcMinutes, 90);
      });

      test('HTF and DXY are HARD gates by default, and neither blocks on missing data', () {
        dotenv.testLoad(fileInput: 'BREAKOUT_FAILED_REVERSAL=true');
        // 2026-09-23: promoted from advisory scoring to real conditions
        // after a reversal logged "HTF bearish, DXY neutral/against" still
        // fired and lost 198 pips.
        expect(AppConfig.breakoutHtfMode, 'block');
        expect(AppConfig.breakoutDxyMode, 'block');
        // The fail-open half of the contract: with the DXY filter itself
        // switched off there is no signal to contradict, so it confirms.
        dotenv.testLoad(fileInput: 'USE_DXY_FILTER=false\nUSE_MOCK_DATA=false');
        expect(DxyFilterService().confirms(TradeDirection.buy), completion(isTrue));
      });

      test('ignores a rejection of a weak break that never qualified as a breakout', () {
        final trigger = engine.findTrigger(
          series([
            [105.1, 105.4, 105.05, 105.2], // tiny poke: fails body/ATR + expansion
            [105.2, 105.3, 104.0, 104.2],
            [104.2, 104.3, 103.2, 103.4],
          ]),
          [level],
          requireRetest: true,
        );
        expect(trigger, isNull);
      });
    });
  });

  group('ICI dynamic ATR Stop Loss', () {
    final risk = RiskEngine();
    // Defaults: iciSlAtrMultiplier 1.5, iciMinStopLossPips 30,
    // riskPercentPerTrade 1%, contract 100oz, lot step 0.01, max lot 5.
    setUp(() => dotenv.testLoad(fileInput: ''));

    test('structure wins when it is the widest of the three terms', () {
      // ATR $2.00 -> 1.5 x 2.00 = $3.00 = 30 pips; floor 30 pips.
      expect(risk.iciStopLossPips(structureSlPips: 85, atr: 2.0), 85);
    });

    test('ATR wins in a volatile session — 1.5 x ATR(14), expressed in pips', () {
      // ATR $4.00 -> 1.5 x 4.00 = $6.00 -> 60 pips, over both other terms.
      expect(risk.iciStopLossPips(structureSlPips: 22, atr: 4.0), 60);
    });

    test('the 30-pip hard floor catches a quiet market with a tight structure', () {
      // ATR $1.00 -> 15 pips, structure 12 pips: both under the floor.
      expect(risk.iciStopLossPips(structureSlPips: 12, atr: 1.0), 30);
    });

    test('a missing ATR simply drops that term instead of failing', () {
      expect(risk.iciStopLossPips(structureSlPips: 45, atr: null), 45);
      expect(risk.iciStopLossPips(structureSlPips: 12, atr: null), 30);
    });

    test('the stop only ever widens — it never tightens the structural one', () {
      for (final structure in [5.0, 29.0, 31.0, 60.0, 150.0]) {
        expect(
          risk.iciStopLossPips(structureSlPips: structure, atr: 3.0),
          greaterThanOrEqualTo(structure),
          reason: 'structure $structure pips',
        );
      }
    });

    test('lot size scales down with the widened stop so account risk stays at 1%', () {
      const equity = 100000.0;
      const pipValuePerLot = 10.0; // 100oz x $0.10

      // The same setup priced with a 30-pip stop and with a 60-pip stop.
      final tightLot = risk.calculateLotSize(equity: equity, stopLossDollars: 30 * TradeSetup.dollarsPerPip);
      final widerLot = risk.calculateLotSize(equity: equity, stopLossDollars: 60 * TradeSetup.dollarsPerPip);

      // Doubling the stop halves the position...
      expect(widerLot, closeTo(tightLot / 2, 0.02));
      // ...and BOTH keep the money at risk inside the 1% cap.
      expect(tightLot * 30 * pipValuePerLot, lessThanOrEqualTo(equity * 0.01));
      expect(widerLot * 60 * pipValuePerLot, lessThanOrEqualTo(equity * 0.01));
      // ...without leaving meaningful room on the table either.
      expect(tightLot * 30 * pipValuePerLot, greaterThan(equity * 0.0098));
      expect(widerLot * 60 * pipValuePerLot, greaterThan(equity * 0.0098));
    });
  });

  group('closedCandlesOnly', () {
    test('drops the forming candle', () {
      final now = DateTime.utc(2026, 9, 14, 10, 7);
      final candles = [
        _c(DateTime.utc(2026, 9, 14, 9, 45), 1, 1, 1, 1),
        _c(DateTime.utc(2026, 9, 14, 10, 0), 1, 1, 1, 1), // closes 10:15 > now
      ];
      expect(closedCandlesOnly(candles, 15, now).length, 1);
    });
    test('keeps a candle that has just closed', () {
      final now = DateTime.utc(2026, 9, 14, 10, 15);
      final candles = [_c(DateTime.utc(2026, 9, 14, 10, 0), 1, 1, 1, 1)];
      expect(closedCandlesOnly(candles, 15, now).length, 1);
    });
  });

  group('evaluateOutcomeOverCandles', () {
    test('ignores wicks from before the trade existed', () {
      final s = _setup(at: DateTime.utc(2026, 9, 14, 10, 20));
      final candles = [
        _c(DateTime.utc(2026, 9, 14, 10, 0), 2400, 2405, 2397, 2400), // pre-entry: touches both
        _c(DateTime.utc(2026, 9, 14, 10, 15), 2400, 2401, 2399, 2400), // contains entry, >2m before
        _c(DateTime.utc(2026, 9, 14, 10, 30), 2400, 2401, 2399.5, 2400),
      ];
      expect(s.evaluateOutcomeOverCandles(candles), isNull);
    });
    test('finds the first touch across skipped candles, SL first on ties', () {
      final s = _setup(at: DateTime.utc(2026, 9, 14, 10, 0, 30));
      final candles = [
        _c(DateTime.utc(2026, 9, 14, 10, 0), 2400, 2401, 2399, 2400),
        _c(DateTime.utc(2026, 9, 14, 10, 15), 2400, 2404.5, 2399, 2404), // TP
        _c(DateTime.utc(2026, 9, 14, 10, 30), 2404, 2404, 2397, 2398), // SL later
      ];
      final r = s.evaluateOutcomeOverCandles(candles)!;
      expect(r.outcome, TradeOutcome.win);
      expect(r.exitPrice, 2404);
    });
  });

  group('evaluateOutcomeAtTick', () {
    test('SELL stops out on ASK, not BID', () {
      final s = _setup(dir: TradeDirection.sell, entry: 2400, sl: 2402, tp: 2396);
      expect(s.evaluateOutcomeAtTick(bid: 2401.8, ask: 2402.1)?.outcome, TradeOutcome.loss);
      expect(s.evaluateOutcomeAtTick(bid: 2395.9, ask: 2396.2), isNull); // ask still above TP
      expect(s.evaluateOutcomeAtTick(bid: 2395.7, ask: 2396.0)?.outcome, TradeOutcome.win);
    });
    test('BUY uses BID', () {
      final s = _setup();
      expect(s.evaluateOutcomeAtTick(bid: 2398.1, ask: 2397.9), isNull);
      expect(s.evaluateOutcomeAtTick(bid: 2398.0, ask: 2398.3)?.outcome, TradeOutcome.loss);
    });
  });

  // Break-Even retired 2026-09-24 ("لا تحرك الستوب لنقطة الدخول ابدا يضل
  // بمحلو يا ستوب يا هدف") — SignalChecker now passes
  // AppConfig.breakEvenEnabled (false) as updateBreakEven into BOTH outcome
  // sweeps, so nothing ever arms the flag. These tests pin the behaviour
  // the sweeps therefore see: a trade that runs to 1R and comes all the way
  // back must ride to the ORIGINAL Stop Loss, never close at Entry for 0.0.
  group('Break-Even disabled — the Stop Loss never moves', () {
    test('a BUY that reaches 1R then reverses rides to the original SL, not Entry', () {
      final s = _setup(entry: 2400, sl: 2398, tp: 2404); // 1R = 2402
      final candles = [
        // Runs past 1R (2402) — with Break-Even this candle armed the flag.
        _c(DateTime.utc(2026, 9, 14, 10, 15), 2400, 2403.5, 2399.5, 2403),
        // Back THROUGH Entry, but not to the SL: still open, not a 0.0 close.
        _c(DateTime.utc(2026, 9, 14, 10, 30), 2403, 2403, 2399, 2399.5),
      ];
      expect(s.evaluateOutcomeOverCandles(candles, updateBreakEven: AppConfig.breakEvenEnabled), isNull);
      expect(s.breakEvenActive, isFalse);
      expect(s.activeStopLoss, 2398);

      // Only the real Stop Loss closes it, for a full -1R.
      final toSl = [...candles, _c(DateTime.utc(2026, 9, 14, 10, 45), 2399.5, 2400, 2397.5, 2398)];
      final r = s.evaluateOutcomeOverCandles(toSl, updateBreakEven: AppConfig.breakEvenEnabled)!;
      expect(r.outcome, TradeOutcome.loss);
      expect(r.exitPrice, 2398);
    });

    test('the same reversal on the tick path also stays open at Entry', () {
      final s = _setup(dir: TradeDirection.sell, entry: 2400, sl: 2402, tp: 2396); // 1R = 2398
      expect(s.evaluateOutcomeAtTick(bid: 2397.8, ask: 2398.0, updateBreakEven: AppConfig.breakEvenEnabled), isNull);
      expect(s.breakEvenActive, isFalse);
      // Back at Entry — a Break-Even trade would have closed here at 0.0.
      expect(s.evaluateOutcomeAtTick(bid: 2399.8, ask: 2400.0, updateBreakEven: AppConfig.breakEvenEnabled), isNull);
      expect(s.activeStopLoss, 2402);
    });
  });

  test('duplicate detection and unique notification ids', () {
    final a = _setup();
    final b = _setup(at: a.detectedAt.add(const Duration(minutes: 5)));
    final c = _setup(entry: 2401);
    expect(b.isDuplicateOf(a), isTrue);
    expect(c.isDuplicateOf(a), isFalse);
    expect(a.notificationId(), isNot(a.notificationId(salt: 1)));
    expect(a.notificationId(), greaterThanOrEqualTo(0));
  });

  test('Tick.fromJson prefers millisecond time and reads ask', () {
    final t = Tick.fromJson({'time': 1757844000, 'time_msc': 1757844000123, 'bid': 2400.1, 'ask': 2400.4, 'last': 0});
    expect(t.time.millisecond, 123);
    expect(t.ask, 2400.4);
  });

  test('HistoryStore round-trips and skips corrupt entries', () async {
    SharedPreferences.setMockInitialValues({
      TradeSetup.historyPrefsKey: ['{not json'],
    });
    await HistoryStore.mutate((h) {
      h.add(_setup());
      return true;
    });
    final loaded = await HistoryStore.load();
    expect(loaded.length, 1);
    expect(loaded.first.entry, 2400);
  });

  test('full mock monitoring cycles complete without errors', () async {
    SharedPreferences.setMockInitialValues({});
    dotenv.testLoad(fileInput: 'USE_MOCK_DATA=true');
    final events = <Map<String, Object?>>[];
    final engine = MonitorEngine(onEvent: events.add);
    await engine.init();
    for (var i = 0; i < 3; i++) {
      await engine.runCycle();
    }
    final cycles = events.where((e) => e['type'] == 'cycle').toList();
    expect(cycles.length, 3);
    for (final e in cycles) {
      expect(e['ok'], isTrue, reason: '${e['status']}');
    }
    // Re-running on the same closed candles must not add duplicates.
    final history = await HistoryStore.load();
    final uids = history.map((s) => '${s.setupType}|${s.direction}|${s.entry}').toList();
    expect(uids.toSet().length, uids.length);
  });
}
