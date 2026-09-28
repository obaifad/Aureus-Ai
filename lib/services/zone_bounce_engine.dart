import '../config/app_config.dart';
import '../models/candle.dart';
import '../models/pivot.dart';
import 'ta_engine.dart';

/// A qualifying Zone Bounce entry — a clean rejection OFF a validated HTF
/// level with NO breakout of it, in a ranging market.
class ZoneBounceTrigger {
  final HtfZone zone;
  final TradeDirection direction;
  final Candle rejectionCandle;
  final int candleIndex;
  final CandlePattern pattern;

  /// The rejection candle's own extreme on the losing side — its wick low
  /// for a BUY, its wick high for a SELL. The Stop Loss sits BEYOND this
  /// (plus a buffer), never at the zone price itself: the wick already
  /// traded through the level, so a stop at the level would sit inside the
  /// move that just got rejected.
  final double rejectionExtreme;

  /// The nearest opposing structural level ahead of the trade, if any —
  /// the far side of the range price is bouncing inside. Take Profit is
  /// CAPPED here when the fixed-ratio target would otherwise land beyond
  /// it. Null when no such level exists ahead of Entry.
  final double? rangeBoundary;

  const ZoneBounceTrigger({
    required this.zone,
    required this.direction,
    required this.rejectionCandle,
    required this.candleIndex,
    required this.pattern,
    required this.rejectionExtreme,
    this.rangeBoundary,
  });

  bool get isBuy => direction == TradeDirection.buy;
}

/// Ranging Market Module — the Zone Bounce Protocol (2026-09-25, explicit
/// request), a SIXTH fully independent strategy tier.
///
/// It exists because the Strict Top-Down HTF Retest Protocol is, by
/// construction, a BREAK-and-retest strategy: its gate 3 requires price to
/// have closed a full zone width THROUGH the level and then come back, and
/// its confirmation gate explicitly rejects a Pinbar. A clean rejection off
/// a level that HOLDS — the classic ranging bounce — can therefore never
/// produce a trade there, no matter how obvious it looks on the chart. That
/// was diagnosed live on 2026-09-25: 39 Key Zones found, a 15M Support
/// $1.66 from price, and no trigger from any tier all day.
///
/// This engine is deliberately ISOLATED from that protocol rather than a
/// loosening of it — same design stance as OrbEngine. It never touches
/// [TaEngine.findExecutionTrigger], shares none of its gates, and carries
/// its own SetupType, Confluence Score and enable flag, so the strict path
/// keeps exactly the safety properties it was given.
///
/// Its own premise is the mirror image of the Top-Down one:
///
///   1. RANGING ONLY — the caller must have NO clear HTF bias (1H
///      undefined, or 1H and 4H disagreeing). A market with a clean
///      trend belongs to the trend engines; this one is for the chop
///      between them.
///   2. A validated HTF zone is TOUCHED (or near-touched) by the last
///      closed candle — see [AppConfig.zoneBounceTouchDollars].
///   3. NO BREAKOUT: that candle must close back on its ORIGINATING side
///      of the level, and no recent candle may have closed decisively
///      through it. A level that broke is not a level that bounced.
///   4. A clean REJECTION shape off the level: Pinbar, Engulfing, or a
///      long rejection wick (see [AppConfig.zoneBounceMinWickRatio]).
///
/// Direction is read from the candle's BEHAVIOUR at the level (which side
/// it wicked into and which side it closed on), not from the zone's
/// "Support"/"Resistance" label. A level's role flips as price crosses it,
/// the label is only a snapshot of how the level was originally found, and
/// trendline zones carry no support/resistance label at all — behaviour is
/// true for all three cases.
class ZoneBounceEngine {
  final TaEngine _ta;

  ZoneBounceEngine({TaEngine? taEngine}) : _ta = taEngine ?? TaEngine();

  /// Scans the [zones] nearest to price for a qualifying bounce off the
  /// LAST CLOSED candle of [candles]. Returns the strongest candidate (see
  /// [_rank]) or null.
  ///
  /// Only the last closed candle is ever considered the rejection candle:
  /// this is an entry AT the rejection, so a bounce that already happened
  /// several candles ago is a missed trade, not a pending one. That is
  /// also what keeps the engine from re-firing the same old bounce on
  /// every later cycle — the failure mode found in ORB on 2026-09-25.
  ZoneBounceTrigger? findTrigger({
    required List<Candle> candles,
    required List<HtfZone> zones,
    required TradeDirection? htfBias,
  }) =>
      diagnose(candles: candles, zones: zones, htfBias: htfBias).trigger;

  /// [findTrigger] with the REASON attached when nothing fires. Not a
  /// second implementation: [findTrigger] is a thin wrapper over this, so a
  /// backtest or a scan note that reports "why not" is reading the exact
  /// gates that decided, and the two cannot drift apart.
  ///
  /// When several of the evaluated zones reject a candle for different
  /// reasons, the reason reported is the one that got FURTHEST through the
  /// gates (the order of [ZoneBounceReject]) — the most informative answer
  /// to "how close was this to a trade".
  ZoneBounceDiagnosis diagnose({
    required List<Candle> candles,
    required List<HtfZone> zones,
    required TradeDirection? htfBias,
  }) {
    // Gate 1 — ranging only. A CLEAR bias means the trend engines own
    // this market; this tier stands down entirely rather than adding a
    // countertrend opinion alongside them.
    if (htfBias != null) return const ZoneBounceDiagnosis.rejected(ZoneBounceReject.biasPresent);
    if (candles.length < 20 || zones.isEmpty) {
      return const ZoneBounceDiagnosis.rejected(ZoneBounceReject.insufficientData);
    }

    final index = candles.length - 1;
    final candle = candles[index];
    if (candle.range <= 0) return const ZoneBounceDiagnosis.rejected(ZoneBounceReject.insufficientData);

    final candidates = <ZoneBounceTrigger>[];
    final rejects = <ZoneBounceReject>[];
    for (final zone in _ta.findNearestZones(
      zones,
      candle.close,
      count: AppConfig.zoneBounceEvaluatedZoneCount,
    )) {
      final result = _evaluateZone(candles: candles, index: index, zone: zone, allZones: zones);
      if (result.trigger != null) {
        candidates.add(result.trigger!);
      } else {
        rejects.add(result.reject!);
      }
    }

    if (candidates.isEmpty) {
      final furthest = rejects.reduce((a, b) => a.index >= b.index ? a : b);
      return ZoneBounceDiagnosis.rejected(furthest);
    }
    candidates.sort((a, b) => _rank(b, candle).compareTo(_rank(a, candle)));
    return ZoneBounceDiagnosis.fired(candidates.first);
  }

  /// Ranks competing bounces when the same candle rejects off more than one
  /// nearby level: a stronger rejection shape first, then the level the
  /// wick actually reached deepest into (the one price genuinely tested).
  double _rank(ZoneBounceTrigger t, Candle candle) {
    final shape = switch (t.pattern) {
      CandlePattern.bullishEngulfing || CandlePattern.bearishEngulfing => 3.0,
      CandlePattern.bullishPinbar || CandlePattern.bearishPinbar => 2.0,
      _ => 1.0,
    };
    final penetration = (t.isBuy ? t.zone.price - candle.low : candle.high - t.zone.price)
        .clamp(0.0, double.infinity);
    return shape * 10 + penetration;
  }

  ({ZoneBounceTrigger? trigger, ZoneBounceReject? reject}) _evaluateZone({
    required List<Candle> candles,
    required int index,
    required HtfZone zone,
    required List<HtfZone> allZones,
  }) {
    ({ZoneBounceTrigger? trigger, ZoneBounceReject? reject}) no(ZoneBounceReject r) =>
        (trigger: null, reject: r);

    final candle = candles[index];
    final level = zone.price;
    final tolerance = AppConfig.zoneBounceTouchDollars;

    // --- Gate 2: the candle actually reached the level ---
    //
    // Its range must overlap the band [level - tolerance, level + tolerance]
    // (the same band for both directions, so a wick, a body, or a candle
    // spanning the level all count as a touch).
    final touched = candle.low <= level + tolerance && candle.high >= level - tolerance;
    if (!touched) return no(ZoneBounceReject.noZoneTouched);

    // --- Gate 3: it closed back on the side price ARRIVED from ---
    //
    // Direction comes from where price WAS, i.e. which side of the level
    // the PREVIOUS candle closed on — not merely which side this candle
    // closes on. That distinction is the whole difference between a bounce
    // and a break: price arriving from above and closing back above bounced
    // off the level (buy); price arriving from above and closing BELOW it
    // went through it, however bearish the candle looks, and the same
    // mirrored from below.
    //
    // (An earlier version keyed the direction on this candle's close alone.
    // That let a breakdown candle with a bearish Engulfing shape masquerade
    // as a "sell bounce" and be caught only later, incidentally, by the
    // broken-level lookback below — found in the 72-hour backtest, where
    // SELLs were being taken off levels labelled Support.)
    final cameFromAbove = candles[index - 1].close > level;
    final closedOnOwnSide = cameFromAbove ? candle.close > level : candle.close < level;
    if (!closedOnOwnSide) return no(ZoneBounceReject.closedThrough);

    final direction = cameFromAbove ? TradeDirection.buy : TradeDirection.sell;
    final bullish = direction == TradeDirection.buy;

    // --- Gate 3b: the level must not have been BROKEN recently ---
    //
    // "No breakout occurs" is about the level's standing, not just this
    // one candle: a level a candle closed decisively through a few bars
    // ago is a broken level being retested (which is the Top-Down
    // protocol's territory, with its own sweep/MSS gates), not a range
    // boundary holding. Measured with the same
    // AppConfig.interestZoneBufferDollars the Top-Down gate uses, so the
    // two tiers agree on what "through the level" means.
    final lookbackStart = (index - AppConfig.zoneBounceBreakLookback).clamp(0, index);
    for (var i = lookbackStart; i < index; i++) {
      final close = candles[i].close;
      final brokeThrough = bullish
          ? close < level - AppConfig.interestZoneBufferDollars
          : close > level + AppConfig.interestZoneBufferDollars;
      if (brokeThrough) return no(ZoneBounceReject.levelBrokenRecently);
    }

    // --- Gate 4: a clean rejection shape off the level ---
    if (_ta.classifyPattern(candles, index) == CandlePattern.doji) return no(ZoneBounceReject.doji);
    final pattern = _rejectionPattern(candles, index, bullish: bullish);
    if (pattern == CandlePattern.none) return no(ZoneBounceReject.noRejectionPattern);

    // No separate "the wick reached the level" check: Gate 2 already
    // required the candle's range to overlap the touch band, and the
    // rejection wick is the candle's own low (buy) / high (sell), so that
    // check would be the same inequality a second time.
    final rejectionExtreme = bullish ? candle.low : candle.high;

    return (
      trigger: ZoneBounceTrigger(
        zone: zone,
        direction: direction,
        rejectionCandle: candle,
        candleIndex: index,
        pattern: pattern,
        rejectionExtreme: rejectionExtreme,
        rangeBoundary: _opposingBoundary(allZones, entry: candle.close, bullish: bullish),
      ),
      reject: null,
    );
  }

  /// The rejection shape, in descending order of strength. Reuses
  /// [TaEngine.classifyPattern]'s Pinbar/Engulfing definitions verbatim
  /// rather than restating them, so this tier and every other one agree on
  /// what those words mean; the third form — a long rejection wick — is
  /// this engine's own, and is deliberately looser than a strict Pinbar
  /// (which additionally demands a small opposite wick). Returns
  /// [CandlePattern.none] when the candle is not a rejection in the
  /// required direction, INCLUDING when it is a Doji: indecision at a
  /// level is not a rejection of it.
  CandlePattern _rejectionPattern(List<Candle> candles, int index, {required bool bullish}) {
    final classified = _ta.classifyPattern(candles, index);
    if (bullish &&
        (classified == CandlePattern.bullishPinbar || classified == CandlePattern.bullishEngulfing)) {
      return classified;
    }
    if (!bullish &&
        (classified == CandlePattern.bearishPinbar || classified == CandlePattern.bearishEngulfing)) {
      return classified;
    }

    // A Doji is explicitly NOT a rejection, even when it carries a long
    // wick into the level: its body is by definition too small to say who
    // won, and this tier's whole premise is that the level held. Checked
    // here rather than left to the wick test below, which a long-legged
    // Doji would otherwise pass.
    if (classified == CandlePattern.doji) return CandlePattern.none;

    final c = candles[index];
    if (c.range <= 0) return CandlePattern.none;
    final wick = bullish ? c.lowerWick : c.upperWick;
    if (wick / c.range < AppConfig.zoneBounceMinWickRatio) return CandlePattern.none;

    // No separate "closed in the trade's favour" check is needed: for a
    // bullish candidate, lowerWick = min(open, close) - low <= close - low,
    // so a lower wick worth >= half the range already forces the close into
    // the upper half of it. The bearish case is the exact mirror. An
    // explicit close-position test here would be unreachable code.
    return bullish ? CandlePattern.bullishPinbar : CandlePattern.bearishPinbar;
  }

  /// The nearest zone AHEAD of [entry] in the trade's direction — the far
  /// side of the range. Used only to CAP Take Profit, never to extend it.
  double? _opposingBoundary(List<HtfZone> zones, {required double entry, required bool bullish}) {
    double? best;
    for (final z in zones) {
      final ahead = bullish ? z.price > entry : z.price < entry;
      if (!ahead) continue;
      if (best == null || (z.price - entry).abs() < (best - entry).abs()) best = z.price;
    }
    return best;
  }

  /// The Stop Loss distance for [trigger], in dollars: beyond the rejection
  /// wick's extreme, plus a buffer that is the LARGER of the fixed
  /// [AppConfig.slBufferDollars] and a volatility-scaled
  /// [AppConfig.zoneBounceSlAtrMultiplier] x ATR(14) — so a stop sits
  /// clear of ordinary noise on a busy day instead of at a constant
  /// distance that is too tight for it. Returns null when [trigger]'s own
  /// geometry is degenerate (entry already at or through the stop).
  double? stopLossFor(ZoneBounceTrigger trigger, {double? atr}) {
    final buffer = atr == null
        ? AppConfig.slBufferDollars
        : (atr * AppConfig.zoneBounceSlAtrMultiplier).clamp(AppConfig.slBufferDollars, double.infinity);
    final entry = trigger.rejectionCandle.close;
    final stop = trigger.isBuy ? trigger.rejectionExtreme - buffer : trigger.rejectionExtreme + buffer;
    final risk = (entry - stop).abs();
    if (risk <= 0) return null;
    return stop;
  }

  /// Take Profit — the Adaptive Target rule (2026-09-25, explicit request):
  ///
  ///   * boundary >= [AppConfig.zoneBounceMinBoundaryR] (1.0R) from Entry:
  ///     the range's far side is a real, reachable target, so Take Profit
  ///     is clipped to it whenever it sits NEARER than the fixed target;
  ///   * boundary < 1.0R away (or none): it is too close to be a target —
  ///     the setup is NOT cancelled and NOT clipped, Take Profit stays
  ///     strictly at [AppConfig.riskRewardRatio] (1:1.8).
  ///
  /// The first branch is a CLIP, never an extension: a boundary sitting
  /// beyond the fixed target leaves Take Profit at 1:1.8 rather than
  /// stretching it out to that level. The request reads "set the TP at the
  /// opposing boundary" for any boundary >= 1.0R, but a literal reading
  /// would let a boundary 5R away turn a 1:1.8 module into a 1:5 one,
  /// contradicting the fixed ratio the same request keeps. Realised R:R is
  /// therefore always within [1.0, [AppConfig.riskRewardRatio]] here;
  /// the caller still applies AppConfig.zoneBounceMinRiskReward to it.
  ///
  /// This replaces the earlier rule that clipped to ANY boundary ahead.
  /// With ~66 Key Zones on the chart there is virtually always one within
  /// cents of Entry, so that rule produced 0.7- to 6-pip targets and the
  /// R:R floor then rejected 10 of 10 otherwise-valid setups in a 12-hour
  /// backtest.
  double takeProfitFor(ZoneBounceTrigger trigger, {required double entry, required double stopLoss}) {
    final risk = (entry - stopLoss).abs();
    final target = trigger.isBuy
        ? entry + AppConfig.riskRewardRatio * risk
        : entry - AppConfig.riskRewardRatio * risk;

    final boundary = trigger.rangeBoundary;
    if (boundary == null || risk <= 0) return target;

    final boundaryR = (boundary - entry).abs() / risk;
    if (boundaryR < AppConfig.zoneBounceMinBoundaryR) return target;

    return trigger.isBuy ? (target < boundary ? target : boundary) : (target > boundary ? target : boundary);
  }
}

/// Why [ZoneBounceEngine] did not fire on a candle, in gate order — the
/// enum's own [index] is the ranking [ZoneBounceEngine.diagnose] uses to
/// pick the reason that got furthest.
enum ZoneBounceReject {
  insufficientData,
  biasPresent,
  noZoneTouched,
  closedThrough,
  levelBrokenRecently,
  doji,
  noRejectionPattern;

  String get label => switch (this) {
        ZoneBounceReject.insufficientData => 'بيانات غير كافية',
        ZoneBounceReject.biasPresent => 'اتجاه HTF واضح — الوحدة تتنحّى',
        ZoneBounceReject.noZoneTouched => 'لم تلمس أي منطقة من أقرب 3',
        ZoneBounceReject.closedThrough => 'أُغلقت عبر المستوى — كسر لا ارتداد',
        ZoneBounceReject.levelBrokenRecently => 'المستوى انكسر خلال آخر شموع',
        ZoneBounceReject.doji => 'شمعة Doji — تردد وليس رفضاً',
        ZoneBounceReject.noRejectionPattern => 'لا نمط رفض (Pinbar/Engulfing/ويك ≥ 50%)',
      };
}

/// Result of [ZoneBounceEngine.diagnose]: either a [trigger], or the
/// [reject] reason that got furthest through the gates.
class ZoneBounceDiagnosis {
  final ZoneBounceTrigger? trigger;
  final ZoneBounceReject? reject;

  const ZoneBounceDiagnosis.fired(ZoneBounceTrigger this.trigger) : reject = null;
  const ZoneBounceDiagnosis.rejected(ZoneBounceReject this.reject) : trigger = null;
}
