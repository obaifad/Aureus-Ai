enum PivotType { high, low }

/// A swing high or swing low detected on the candle series.
class Pivot {
  final int index; // index inside the candle list it was detected on
  final DateTime time;
  final double price;
  final PivotType type;

  const Pivot({
    required this.index,
    required this.time,
    required this.price,
    required this.type,
  });
}

/// A dynamic trendline built from >= 3 pivots of the same type,
/// expressed as a simple linear function: price = slope * x + intercept
/// where x is the candle index.
class Trendline {
  final double slope;
  final double intercept;
  final PivotType basedOn; // "low" => ascending support line, "high" => descending resistance line
  final List<Pivot> pivots;

  const Trendline({
    required this.slope,
    required this.intercept,
    required this.basedOn,
    required this.pivots,
  });

  /// Price the trendline predicts at candle index [x].
  double priceAt(int x) => slope * x + intercept;

  bool get isAscending => slope > 0;
  bool get isDescending => slope < 0;
}

/// A horizontal support/resistance zone built from repeated price
/// reactions (at least [AppConfig.minSrTouches] touches).
class SrLevel {
  final double price;
  final int touches;
  final bool isSupport;

  const SrLevel({
    required this.price,
    required this.touches,
    required this.isSupport,
  });
}

enum CandlePattern {
  bullishPinbar,
  bearishPinbar,
  bullishEngulfing,
  bearishEngulfing,
  bullishMomentum,
  bearishMomentum,
  bullishAbsorption,
  bearishAbsorption,
  doji,
  none,
}

extension CandlePatternLabel on CandlePattern {
  /// The pattern's shape only, with the bullish/bearish direction already
  /// baked into the enum name stripped back out — for text that prepends
  /// its own direction word (e.g. "a bearish $shapeLabel confirmation"),
  /// so it doesn't read "a bearish bearishEngulfing confirmation".
  String get shapeLabel => switch (this) {
        CandlePattern.bullishPinbar || CandlePattern.bearishPinbar => 'Pinbar',
        CandlePattern.bullishEngulfing || CandlePattern.bearishEngulfing => 'Engulfing',
        CandlePattern.bullishMomentum || CandlePattern.bearishMomentum => 'Momentum',
        CandlePattern.bullishAbsorption || CandlePattern.bearishAbsorption => 'Absorption',
        CandlePattern.doji => 'Doji',
        CandlePattern.none => 'None',
      };
}

enum TradeDirection { buy, sell }

/// Outcome of a fired TradeSetup, tracked by SignalChecker's per-cycle
/// sweep (2026-09-11 — "فينا نعمل Watcher بالتطبيق؟"): [open] until the
/// live price crosses either the Stop Loss or Take Profit, then locked to
/// [win] or [loss] and never re-evaluated again.
enum TradeOutcome { open, win, loss }

/// The kind of structure a [SetupZone] was found at.
///
/// `confluence`/`breakoutRetest`/`trendlineBounce`/`srBounce` are the
/// original single-timeframe zone types (kept only so old persisted signal
/// history — SharedPreferences JSON with these `setup_type` values — still
/// deserializes; TaEngine no longer produces them). The Strict Top-Down
/// Dual-Mode strategy (see TaEngine.buildHtfZones / findExecutionTrigger)
/// produces `htfReversal`, `htfRetest`, or `momentumBreakout` on 1M/5M, and
/// `absorption15m` (TaEngine.find15mAbsorptionTrigger, 2026-09-10) on 15M.
enum SetupType {
  confluence,
  breakoutRetest,
  trendlineBounce,
  srBounce,
  htfReversal,
  htfRetest,
  momentumBreakout,
  absorption15m,
  // ICT / Smart-Money-Concepts strategy (ict_engine.dart, 2026-09-12) — an
  // independent strategy layer, see AppConfig's "ICT" section for context.
  ictLiquiditySweepReversal,
  ictOrderBlock,
  ictFairValueGap,
  ictBreakerBlock,
  ictTrendlineContinuation,
  // Impulse-Correction-Impulse strategy (impulse_correction_engine.dart,
  // 2026-09-13) — a third independent strategy layer: a trend-continuation
  // entry at the end of a corrective pullback following a strong impulsive
  // leg. See AppConfig's "Impulse-Correction-Impulse" section.
  impulseCorrectionContinuation,
}

extension SetupTypeLabel on SetupType {
  /// Short label used in signal text/notifications, e.g. "1H S/R Retest Buy".
  String get label => switch (this) {
        SetupType.confluence => 'Confluence',
        SetupType.breakoutRetest => 'Breakout & Retest',
        SetupType.trendlineBounce => 'Trendline Bounce',
        SetupType.srBounce => 'S/R Retest',
        SetupType.htfReversal => 'HTF Reversal',
        SetupType.htfRetest => 'HTF Retest',
        SetupType.momentumBreakout => 'MOMENTUM / BREAKOUT',
        SetupType.absorption15m => '15M Higher Low / Lower High Absorption',
        SetupType.ictLiquiditySweepReversal => 'ICT Liquidity Sweep Reversal',
        SetupType.ictOrderBlock => 'ICT Order Block Retest',
        SetupType.ictFairValueGap => 'ICT Fair Value Gap Fill',
        SetupType.ictBreakerBlock => 'ICT Breaker / Mitigation Retest',
        SetupType.ictTrendlineContinuation => 'ICT Trendline Continuation',
        SetupType.impulseCorrectionContinuation => 'Impulse-Correction-Impulse Continuation',
      };
}

/// Which of the 3 independent strategy engines produced a [SetupType] —
/// used by trade_history_screen.dart's per-strategy analytics breakdown.
enum StrategyFamily { topDown, ict, ici }

extension SetupTypeStrategyFamily on SetupType {
  StrategyFamily get strategyFamily => switch (this) {
        SetupType.ictLiquiditySweepReversal ||
        SetupType.ictOrderBlock ||
        SetupType.ictFairValueGap ||
        SetupType.ictBreakerBlock ||
        SetupType.ictTrendlineContinuation =>
          StrategyFamily.ict,
        SetupType.impulseCorrectionContinuation => StrategyFamily.ici,
        _ => StrategyFamily.topDown,
      };
}

extension StrategyFamilyLabel on StrategyFamily {
  String get label => switch (this) {
        StrategyFamily.topDown => 'Top-Down',
        StrategyFamily.ict => 'ICT',
        StrategyFamily.ici => 'ICI',
      };
}

/// A candidate entry zone RiskEngine prices a setup against. [trendline]
/// and/or [srLevel] may be null — e.g. a Strict Top-Down trigger only
/// carries a flattened [zonePrice] (see [HtfZone]), no raw trendline/S-R
/// objects. [zonePrice] is always populated and is the single reference
/// price RiskEngine anchors the Stop Loss to, regardless of source.
class SetupZone {
  final SetupType type;
  final Trendline? trendline;
  final SrLevel? srLevel;
  final double zonePrice;
  final int candleIndex;

  const SetupZone({
    required this.type,
    this.trendline,
    this.srLevel,
    required this.zonePrice,
    required this.candleIndex,
  });
}

/// A structural "Key Zone" identified strictly from 15M/1H candles (see
/// TaEngine.buildHtfZones) — a trendline's projection is baked into
/// [price] "as of now" at build time rather than carried as index-
/// dependent slope/intercept, so it can be compared directly against the
/// 1M/5M live price with no risk of mixing index scales across timeframes.
class HtfZone {
  final double price;
  final String source; // e.g. "1H Support", "15M Trendline (ascending)"
  const HtfZone({required this.price, required this.source});
}

/// A valid 1M/5M/15M price-action trigger — either at a pre-identified
/// [HtfZone] (Reversal/Retest, or 15M Higher Low / Lower High Absorption)
/// or from the breakout candle's own wick (Momentum) — the only thing that
/// can produce a TradeSetup under the Strict Top-Down Dual-Mode strategy.
/// [type] is [SetupType.htfReversal], [SetupType.htfRetest],
/// [SetupType.momentumBreakout], or [SetupType.absorption15m].
class ExecutionTrigger {
  final SetupType type;
  final HtfZone zone;
  final CandlePattern pattern;
  final int candleIndex;

  const ExecutionTrigger({
    required this.type,
    required this.zone,
    required this.pattern,
    required this.candleIndex,
  });
}
