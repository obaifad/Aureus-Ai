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
enum TradeOutcome { open, win, loss, manualClose }

/// The kind of structure a [SetupZone] was found at.
///
/// `confluence`/`breakoutRetest`/`trendlineBounce`/`srBounce`/`htfReversal`/
/// `absorption15m`/`momentumBreakout` are retired types (kept only so old
/// persisted signal history — SharedPreferences JSON with these
/// `setup_type` values — still deserializes; TaEngine no longer produces
/// them). `htfReversal` — a fresh first-touch rejection at an unbroken
/// zone — was retired 2026-09-18 with the HTF Retest Protocol, having
/// already been rejected outright by SignalChecker since 2026-09-17.
/// `absorption15m` — the standalone 15M Higher Low / Lower High Absorption
/// strategy — was retired the same day (explicit request); its underlying
/// pattern classifier (TaEngine.classifyStrongAbsorption) lives on as a
/// shared confirmation check for the HTF Retest Protocol and
/// ImpulseCorrectionEngine, just no longer as an independent path into a
/// trade. `momentumBreakout` — the standalone "fire on a decisive
/// expansion candle near any zone with no confirmed retest" fallback —
/// was retired 2026-09-18 too (explicit request): TaEngine.classifyMomentum
/// lives on as one of the HTF Retest Protocol's own confirmation checks,
/// just no longer as an independent trigger path. The Strict Top-Down
/// strategy (see TaEngine.buildHtfZones / findExecutionTrigger) now
/// produces only `htfRetest`, on 15M.
enum SetupType {
  confluence,
  breakoutRetest,
  trendlineBounce,
  srBounce,
  htfReversal,
  htfRetest,
  /// Retired 2026-09-18 — kept only so old persisted history deserializes.
  momentumBreakout,
  /// Retired 2026-09-18 — kept only so old persisted history deserializes.
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
  // Opening Range Breakout strategy (orb_engine.dart, 2026-09-18) — a
  // fourth independent strategy layer, deliberately isolated from every
  // other tier: a mechanical breakout of the first 30 minutes of the
  // London or New York session, with no HTF zone, structure bias, or
  // candlestick-pattern dependency at all. A retest of the broken boundary
  // is mandatory before entry (the old immediate no-retest mode was
  // removed). See AppConfig's "Opening Range Breakout" section.
  orbBreakout,
  // Breakout/Momentum strategy (breakout_momentum_engine.dart, 2026-09-18)
  // — a fifth independent strategy layer: an M5 candle-close breakout of a
  // structural level (previous session High/Low, a configurable Opening
  // Range, Previous Day High/Low, or an HTF S/R zone), gated on an
  // ATR(14)-normalized body AND a close-location wick filter — never a
  // touch or wick-only penetration. See AppConfig's "Breakout/Momentum"
  // section.
  breakoutMomentum,
  // Ranging Market Module — Zone Bounce Protocol (zone_bounce_engine.dart,
  // 2026-09-25) — a sixth independent strategy layer, and the mirror image
  // of htfRetest: a clean rejection off an HTF level that HOLDS, taken only
  // while there is NO clear HTF bias. The Top-Down protocol cannot produce
  // this setup by construction (it requires a decisive close THROUGH the
  // level first, and rejects a Pinbar as confirmation), which is exactly
  // why this is a separate tier rather than a loosening of that one. See
  // AppConfig's "Ranging Market Module" section.
  rangingBounce,
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
        SetupType.orbBreakout => 'Opening Range Breakout',
        SetupType.breakoutMomentum => 'Breakout / Momentum',
        SetupType.rangingBounce => 'Range Zone Bounce',
      };
}

/// Which of the six independent strategy engines produced a [SetupType] —
/// used by trade_history_screen.dart's per-strategy analytics breakdown.
enum StrategyFamily { topDown, ict, ici, orb, breakout, rangingBounce }

extension SetupTypeStrategyFamily on SetupType {
  StrategyFamily get strategyFamily => switch (this) {
        SetupType.ictLiquiditySweepReversal ||
        SetupType.ictOrderBlock ||
        SetupType.ictFairValueGap ||
        SetupType.ictBreakerBlock ||
        SetupType.ictTrendlineContinuation =>
          StrategyFamily.ict,
        SetupType.impulseCorrectionContinuation => StrategyFamily.ici,
        SetupType.orbBreakout => StrategyFamily.orb,
        SetupType.breakoutMomentum => StrategyFamily.breakout,
        SetupType.rangingBounce => StrategyFamily.rangingBounce,
        _ => StrategyFamily.topDown,
      };
}

extension StrategyFamilyLabel on StrategyFamily {
  String get label => switch (this) {
        StrategyFamily.topDown => 'Top-Down',
        StrategyFamily.ict => 'ICT',
        StrategyFamily.ici => 'ICI',
        StrategyFamily.orb => 'ORB',
        StrategyFamily.breakout => 'Breakout',
        StrategyFamily.rangingBounce => 'Range Bounce',
      };
}

/// A candidate entry zone RiskEngine prices a setup against. [trendline]
/// and/or [srLevel] may be null — e.g. a Strict Top-Down trigger only
/// carries a flattened [zonePrice] (see [HtfZone]), no raw trendline/S-R
/// objects. [zonePrice] is always populated and is the reference price
/// RiskEngine anchors the Stop Loss to whenever [swingAnchor] is absent.
class SetupZone {
  final SetupType type;
  final Trendline? trendline;
  final SrLevel? srLevel;
  final double zonePrice;
  final int candleIndex;

  /// The swept swing extreme the Stop Loss must sit BEHIND (2026-09-18, HTF
  /// Retest Protocol) — the price at which the liquidity grab that set up
  /// this entry would be proven wrong. When present it replaces [zonePrice]
  /// as the structural anchor entirely: a stop at the zone boundary sits
  /// inside the sweep that just happened and gets taken out by it.
  final double? swingAnchor;

  /// The next untapped liquidity / HTF level in the trade's favour
  /// (2026-09-18) — RiskEngine prices Take Profit AT this level instead of
  /// a blind [AppConfig.riskRewardRatio] multiple, since that is where
  /// price is actually expected to react. Null when no such level exists
  /// ahead of Entry, in which case the fixed ratio is used.
  final double? liquidityTarget;

  const SetupZone({
    required this.type,
    this.trendline,
    this.srLevel,
    required this.zonePrice,
    required this.candleIndex,
    this.swingAnchor,
    this.liquidityTarget,
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

/// A valid 15M price-action trigger at a pre-identified [HtfZone], confirmed
/// by the HTF Retest Protocol — the only thing that can produce a
/// TradeSetup under the Strict Top-Down strategy. [type] is always
/// [SetupType.htfRetest] (the standalone Momentum/Breakout fallback path
/// was removed 2026-09-18).
class ExecutionTrigger {
  final SetupType type;
  final HtfZone zone;
  final CandlePattern pattern;
  final int candleIndex;

  /// Carried through to [SetupZone.swingAnchor] / [SetupZone.liquidityTarget]
  /// — only the HTF Retest Protocol populates these; every other path
  /// leaves them null and keeps RiskEngine's zone-anchored Stop Loss and
  /// fixed-ratio Take Profit.
  final double? swingAnchor;
  final double? liquidityTarget;

  const ExecutionTrigger({
    required this.type,
    required this.zone,
    required this.pattern,
    required this.candleIndex,
    this.swingAnchor,
    this.liquidityTarget,
  });
}
