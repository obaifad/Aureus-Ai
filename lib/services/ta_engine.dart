import 'dart:math';
import '../config/app_config.dart';
import '../models/candle.dart';
import '../models/pivot.dart';

/// Pure technical-analysis / geometry engine. No networking, no state —
/// every method is a deterministic function of the candle list it's given,
/// which makes it trivial to unit test.
class TaEngine {
  // ---------------------------------------------------------------------
  // 1) SWING PIVOT DETECTION
  // ---------------------------------------------------------------------
  /// A candle at index i is a pivot high if its high is the max within
  /// [i-lookback, i+lookback], and symmetrically for pivot lows.
  List<Pivot> findPivots(List<Candle> candles, {int lookback = 3}) {
    final List<Pivot> pivots = [];

    for (int i = lookback; i < candles.length - lookback; i++) {
      final window = candles.sublist(i - lookback, i + lookback + 1);
      final double h = candles[i].high;
      final double l = candles[i].low;

      final bool isHigh = window.every((c) => c.high <= h) &&
          window.where((c) => c.high == h).length == 1;
      final bool isLow = window.every((c) => c.low >= l) &&
          window.where((c) => c.low == l).length == 1;

      if (isHigh) {
        pivots.add(Pivot(index: i, time: candles[i].time, price: h, type: PivotType.high));
      } else if (isLow) {
        pivots.add(Pivot(index: i, time: candles[i].time, price: l, type: PivotType.low));
      }
    }
    return pivots;
  }

  // ---------------------------------------------------------------------
  // 2) DYNAMIC TRENDLINES (least-squares fit through same-type pivots)
  // ---------------------------------------------------------------------
  /// Builds an ascending trendline from the most recent swing LOWS
  /// (support) and a descending trendline from the most recent swing
  /// HIGHS (resistance), each requiring >= AppConfig.minTrendlinePivots.
  List<Trendline> buildTrendlines(List<Pivot> pivots) {
    final List<Trendline> lines = [];

    final lows = pivots.where((p) => p.type == PivotType.low).toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    final highs = pivots.where((p) => p.type == PivotType.high).toList()
      ..sort((a, b) => a.index.compareTo(b.index));

    final ascending = _fitLine(_recent(lows, 4), PivotType.low);
    if (ascending != null && ascending.isAscending) lines.add(ascending);

    final descending = _fitLine(_recent(highs, 4), PivotType.high);
    if (descending != null && descending.isDescending) lines.add(descending);

    return lines;
  }

  List<Pivot> _recent(List<Pivot> pts, int maxCount) =>
      pts.length <= maxCount ? pts : pts.sublist(pts.length - maxCount);

  Trendline? _fitLine(List<Pivot> pts, PivotType basedOn) {
    if (pts.length < AppConfig.minTrendlinePivots) return null;

    // Ordinary least squares: price = slope * index + intercept
    final n = pts.length;
    final xs = pts.map((p) => p.index.toDouble()).toList();
    final ys = pts.map((p) => p.price).toList();

    final xMean = xs.reduce((a, b) => a + b) / n;
    final yMean = ys.reduce((a, b) => a + b) / n;

    double num = 0, den = 0;
    for (int i = 0; i < n; i++) {
      num += (xs[i] - xMean) * (ys[i] - yMean);
      den += (xs[i] - xMean) * (xs[i] - xMean);
    }
    if (den == 0) return null;

    final slope = num / den;
    final intercept = yMean - slope * xMean;

    return Trendline(slope: slope, intercept: intercept, basedOn: basedOn, pivots: pts);
  }

  // ---------------------------------------------------------------------
  // 3) HORIZONTAL SUPPORT / RESISTANCE (clustering of pivot prices)
  // ---------------------------------------------------------------------
  List<SrLevel> findSrLevels(List<Pivot> pivots, {double clusterWidth = 1.5}) {
    final List<SrLevel> levels = [];
    final sorted = [...pivots]..sort((a, b) => a.price.compareTo(b.price));

    int i = 0;
    while (i < sorted.length) {
      int j = i;
      final List<Pivot> cluster = [sorted[i]];
      while (j + 1 < sorted.length && (sorted[j + 1].price - cluster.first.price) <= clusterWidth) {
        j++;
        cluster.add(sorted[j]);
      }

      if (cluster.length >= AppConfig.minSrTouches) {
        final avgPrice = cluster.map((p) => p.price).reduce((a, b) => a + b) / cluster.length;
        final lowTouches = cluster.where((p) => p.type == PivotType.low).length;
        final highTouches = cluster.length - lowTouches;
        levels.add(SrLevel(
          price: avgPrice,
          touches: cluster.length,
          isSupport: lowTouches >= highTouches,
        ));
      }
      i = j + 1;
    }
    return levels;
  }

  // ---------------------------------------------------------------------
  // 4) CANDLESTICK PATTERN DETECTION
  // ---------------------------------------------------------------------
  CandlePattern classifyPattern(List<Candle> candles, int index) {
    if (index < 1 || index >= candles.length) return CandlePattern.none;
    final c = candles[index];
    final prev = candles[index - 1];

    // Doji: body is tiny relative to the candle's range.
    if (c.range > 0 && c.bodySize / c.range < 0.1) return CandlePattern.doji;

    // Pinbar (hammer / shooting star): one wick >= 2x the body, small
    // opposite wick.
    if (c.bodySize > 0) {
      if (c.lowerWick >= c.bodySize * 2 && c.upperWick <= c.bodySize * 0.5) {
        return CandlePattern.bullishPinbar;
      }
      if (c.upperWick >= c.bodySize * 2 && c.lowerWick <= c.bodySize * 0.5) {
        return CandlePattern.bearishPinbar;
      }
    }

    // Engulfing: current body fully engulfs the previous body and flips
    // direction.
    if (prev.isBearish && c.isBullish && c.close >= prev.open && c.open <= prev.close) {
      return CandlePattern.bullishEngulfing;
    }
    if (prev.isBullish && c.isBearish && c.close <= prev.open && c.open >= prev.close) {
      return CandlePattern.bearishEngulfing;
    }

    return CandlePattern.none;
  }

  // ---------------------------------------------------------------------
  // 4b) MOMENTUM / BREAKOUT DETECTION
  // ---------------------------------------------------------------------
  /// A candle at [index] counts as a Momentum/Breakout candle when it is
  /// BOTH a decisive, wide-bodied candle (body dominates its own range —
  /// the opposite of a Pinbar/Doji) AND meaningfully larger than the
  /// recent average range (a genuine expansion, not just an ordinary bar
  /// that happens to close near its high/low). No longer an independent
  /// trigger path on its own (that standalone fallback was removed from
  /// findExecutionTrigger 2026-09-18) — now used only as one of
  /// [_decisiveConfirmation]'s confirmation standards inside the HTF Retest
  /// Protocol, plus by ImpulseCorrectionEngine and IctEngine.
  CandlePattern classifyMomentum(List<Candle> candles, int index, {int lookback = 20}) {
    if (index < 0 || index >= candles.length) return CandlePattern.none;
    final c = candles[index];
    if (c.range <= 0) return CandlePattern.none;

    // Decisive body: at least 65% of the candle's own range, so a candle
    // with a long rejecting wick (a Pinbar) never also qualifies here.
    final bodyRatio = c.bodySize / c.range;
    if (bodyRatio < 0.65) return CandlePattern.none;

    // Expansion: this candle's range must clear 1.5x the recent average —
    // an ordinary directional candle on a quiet day shouldn't count.
    final start = (index - lookback).clamp(0, index);
    final priorRanges = candles.sublist(start, index).map((x) => x.range).where((r) => r > 0).toList();
    if (priorRanges.isEmpty) return CandlePattern.none;
    final avgRange = priorRanges.reduce((a, b) => a + b) / priorRanges.length;
    if (c.range < avgRange * 1.5) return CandlePattern.none;

    return c.isBullish ? CandlePattern.bullishMomentum : CandlePattern.bearishMomentum;
  }

  // ---------------------------------------------------------------------
  // 5) STRICT TOP-DOWN STRATEGY (HTF RETEST PROTOCOL)
  //    a) buildHtfZones — structural S/R + trendlines from 15M/1H/4H ONLY
  //       (2026-09-10: 4H added). 1M/5M are never used to seed a new zone.
  //    b) findExecutionTrigger — the ONLY thing that can produce a setup:
  //       the HTF Retest Protocol at one of those pre-identified HTF zones
  //       (see 5b below). 15M is the only execution timeframe (2026-09-14)
  //       — this method itself is fully timeframe-agnostic, operating on
  //       whatever candle list it's given. (15M Higher Low / Lower High
  //       Absorption was a third, independent path here, retired
  //       2026-09-18 — see section 6 below; the standalone Momentum/
  //       Breakout fallback path was removed the same day, explicit
  //       request — no entry without a confirmed retest anymore.)
  // ---------------------------------------------------------------------

  /// Builds the pool of structural "Key Zones" a Strict Top-Down strategy
  /// is allowed to trade against — every trendline and S/R level found on
  /// [candles15m], [candles1h], AND [candles4h] independently (2026-09-10:
  /// 4H added as its own zone source, not just a bias timeframe), each
  /// flattened to a concrete "as of now" price (see [HtfZone]) so it can be
  /// compared directly against the live price without mixing index scales
  /// across timeframes. Higher-timeframe zones aren't inherently "more"
  /// here — [findNearestZone] is what gives them priority when picking
  /// which zone to trade against.
  List<HtfZone> buildHtfZones({
    required List<Candle> candles15m,
    required List<Candle> candles1h,
    required List<Candle> candles4h,
  }) {
    final zones = <HtfZone>[];

    void addFrom(List<Candle> candles, String label) {
      if (candles.isEmpty) return;
      final pivots = findPivots(candles);
      final trendlines = buildTrendlines(pivots);
      final srLevels = findSrLevels(pivots);
      final lastIndex = candles.length - 1;

      for (final line in trendlines) {
        zones.add(HtfZone(
          price: line.priceAt(lastIndex),
          source: '$label Trendline (${line.isAscending ? "ascending" : "descending"})',
        ));
      }
      for (final sr in srLevels) {
        zones.add(HtfZone(
          price: sr.price,
          source: '$label ${sr.isSupport ? "Support" : "Resistance"}',
        ));
      }
    }

    addFrom(candles15m, '15M');
    addFrom(candles1h, '1H');
    addFrom(candles4h, '4H');
    return zones;
  }

  /// Finds the nearest [zones] entry to [price], giving higher-timeframe
  /// zones priority over lower-timeframe ones when they're reasonably
  /// close together (2026-09-10 — "الأزمنة الأعلى خطوطها هي الأقوى": a
  /// larger structural level should win a near-tie against a smaller one,
  /// not just whichever happens to sit a few cents closer). Implemented as
  /// a distance handicap subtracted only for RANKING which zone counts as
  /// nearest — every caller must still measure the REAL, unmodified
  /// distance to whichever zone this returns for any eligibility/buffer
  /// math, never this handicapped value. A 15M zone that's genuinely much
  /// closer than any 1H/4H zone still wins its own handicap gap.
  HtfZone? findNearestZone(List<HtfZone> zones, double price) {
    HtfZone? nearest;
    var bestRank = double.infinity;
    for (final z in zones) {
      final raw = (price - z.price).abs();
      final handicap = z.source.startsWith('4H')
          ? 2.0
          : z.source.startsWith('1H')
              ? 1.0
              : 0.0;
      final rank = raw - handicap;
      if (rank < bestRank) {
        bestRank = rank;
        nearest = z;
      }
    }
    return nearest;
  }

  /// The [count] zones genuinely NEAREST to [price], closest first, ranked
  /// by TRUE distance with NO timeframe handicap (2026-09-25, Multi-Zone
  /// Evaluation fix).
  ///
  /// [findNearestZone] above returns exactly one zone and subtracts a
  /// handicap from higher-timeframe zones when ranking, so a genuinely
  /// closer level can lose and then never be evaluated at all. Observed
  /// live on 2026-09-25: a 15M Support $1.66 from price lost to a 1H
  /// Support $2.33 away (2.33 - 1.00 < 1.66), so the only level the engine
  /// examined that cycle was not the one price was actually reacting at.
  ///
  /// That handicap is correct for its own caller — the Top-Down protocol
  /// trades ONE zone and should prefer the bigger structure in a near-tie —
  /// so it is left exactly as it is here. This is an additional entry point
  /// for callers that evaluate SEVERAL zones and therefore have no tie to
  /// break: whichever zone actually produces a valid setup wins, which is a
  /// better answer than guessing beforehand. Duplicate prices are kept; two
  /// timeframes independently finding the same level is confluence, and the
  /// caller's own scoring is where that belongs.
  List<HtfZone> findNearestZones(List<HtfZone> zones, double price, {int count = 3}) {
    if (count <= 0) return const [];
    final sorted = [...zones]..sort(
        (a, b) => (price - a.price).abs().compareTo((price - b.price).abs()),
      );
    return sorted.take(count).toList();
  }

  /// The ONLY entry point into a trade under the Strict Top-Down strategy:
  /// finds the nearest of [htfZones] to the current price, then requires
  /// the full HTF Retest Protocol (see [_tryHtfRetestProtocol]) to confirm
  /// there — a real liquidity sweep + structure shift + retest sequence.
  /// Skipped entirely when the caller has no clear [htfBias], since the
  /// whole path is defined as a with-trend continuation.
  ///
  /// The Momentum/Breakout fallback path (fire immediately on a decisive
  /// expansion candle near any zone when no retest was confirmed) was
  /// removed 2026-09-18, explicit request — it let a wide-bodied candle
  /// alone justify a Top-Down entry with no retest at all, which is looser
  /// than the strategy's own "confirmed retest" premise. [classifyMomentum]
  /// stays in use elsewhere (as one of [_decisiveConfirmation]'s own
  /// confirmation standards *inside* the retest protocol, and in
  /// ImpulseCorrectionEngine/IctEngine) — only this standalone fallback
  /// trigger is gone. [SetupType.momentumBreakout] is kept only so old
  /// persisted signal history still deserializes.
  ///
  /// Returns null when the retest protocol finds nothing, or when
  /// [htfZones]/[candles] are empty. [candles] is used *only* for these
  /// pattern/structure checks — never to derive a new structural zone of
  /// its own — and this method is fully timeframe-agnostic (SignalChecker
  /// passes 15M, the only execution timeframe since 2026-09-14).
  ExecutionTrigger? findExecutionTrigger({
    required List<Candle> candles,
    required List<HtfZone> htfZones,
    TradeDirection? htfBias,
    int lookback = 15,
  }) {
    if (candles.isEmpty || htfZones.isEmpty || htfBias == null) return null;
    final lastIndex = candles.length - 1;
    final lastPrice = candles[lastIndex].close;

    final nearest = findNearestZone(htfZones, lastPrice);
    if (nearest == null) return null;

    return _tryHtfRetestProtocol(
      candles: candles,
      htfZones: htfZones,
      nearest: nearest,
      htfBias: htfBias,
      lookback: lookback,
    );
  }

  // ---------------------------------------------------------------------
  // 5b) HTF RETEST PROTOCOL (2026-09-18)
  // ---------------------------------------------------------------------

  /// The strict, textbook Smart-Money retest sequence that replaced the old
  /// "a Pinbar/Engulfing at a zone price happened to have closed far from
  /// recently" Reversal/Retest path. Every gate below must pass, IN ORDER;
  /// failing any one produces no trigger at all. [SetupType.htfReversal] —
  /// the old fresh-first-touch variant — is gone with it, having already
  /// been rejected outright by SignalChecker since 2026-09-17.
  ///
  ///  1. HTF Zone — [nearest], the strongest structural level to price.
  ///  2. HTF Trend/Bias — [htfBias], a strict 1H+4H swing-structure
  ///     consensus computed by the caller. The trade only ever goes WITH
  ///     it, so this path can no longer fire countertrend the way the old
  ///     one could through SignalChecker's Break & Retest exemption.
  ///  3. Price broke DECISIVELY through the zone in the bias direction and
  ///     then came back INTO it — a genuine Break & Retest, in that order,
  ///     rather than a first touch or a signal fired from far away.
  ///  4. Liquidity Sweep — resting liquidity was actually taken first,
  ///     either at a recent swing ([findLiquiditySweep], the stronger
  ///     reading) or at the zone itself ([_isInstitutionalAbsorption]).
  ///     Whichever extreme it reached becomes the Stop Loss anchor.
  ///  5. Market Structure Shift — the last candle closes beyond the swing
  ///     that framed the move into that sweep ([_findStructureShift]).
  ///     This is the step that separates an entry from a stop hunt still
  ///     in progress.
  ///  6. The MSS candle itself must be decisive ([_decisiveConfirmation]):
  ///     displacement, Engulfing or strong Absorption. A Pinbar or Doji
  ///     poking marginally past the level is not a structure shift.
  ///
  /// The returned trigger carries [ExecutionTrigger.swingAnchor] (the swept
  /// extreme — RiskEngine puts the Stop Loss behind THAT, not behind the
  /// zone boundary, which sits inside the sweep that just happened) and
  /// [ExecutionTrigger.liquidityTarget] (the next untapped swing/HTF level
  /// in the trade's favour, which RiskEngine prices Take Profit at instead
  /// of a blind fixed multiple).
  ExecutionTrigger? _tryHtfRetestProtocol({
    required List<Candle> candles,
    required List<HtfZone> htfZones,
    required HtfZone nearest,
    required TradeDirection htfBias,
    required int lookback,
  }) {
    final lastIndex = candles.length - 1;
    final last = candles[lastIndex];
    final bullish = htfBias == TradeDirection.buy;
    final windowStart = (lastIndex - lookback).clamp(0, lastIndex);

    // Gate 3a — a close a full zone width beyond the level (see
    // AppConfig.interestZoneBufferDollars): a candle closing on the zone's
    // own far edge is still inside it, not through it.
    int? breakIndex;
    for (int i = windowStart; i < lastIndex; i++) {
      final close = candles[i].close;
      final through = bullish
          ? close > nearest.price + AppConfig.interestZoneBufferDollars
          : close < nearest.price - AppConfig.interestZoneBufferDollars;
      if (through) {
        breakIndex = i;
        break;
      }
    }
    if (breakIndex == null) return null;

    // Gate 3b — and price came back to the zone AFTER that break.
    var retested = false;
    for (int i = breakIndex + 1; i <= lastIndex; i++) {
      if (candles[i].low <= nearest.price && candles[i].high >= nearest.price) {
        retested = true;
        break;
      }
    }
    if (!retested) return null;

    // Gate 4 — both sweep readings are collected rather than short-
    // circuiting on the first: when both fired, the Stop Loss belongs
    // behind whichever ran further.
    final swingSweep = findLiquiditySweep(candles, bullish: bullish, minSweepIndex: breakIndex);
    final zoneSweep = _findZoneSweep(candles, breakIndex, lastIndex, nearest.price, bullish: bullish);
    if (swingSweep == null && zoneSweep == null) return null;

    final sweepIndex = swingSweep?.sweepIndex ?? zoneSweep!.index;
    final sweptExtremes = [
      if (swingSweep != null) swingSweep.sweptExtreme,
      if (zoneSweep != null) zoneSweep.extreme,
    ];
    final swingAnchor = sweptExtremes.reduce((a, b) => bullish ? min(a, b) : max(a, b));
    final sweepLabel = swingSweep != null && zoneSweep != null
        ? 'Liquidity Sweep (swing + zone)'
        : swingSweep != null
            ? 'Liquidity Sweep (swing)'
            : 'Liquidity Sweep (zone)';

    // Gate 5 — MSS/CHoCH.
    final shiftLevel = _findStructureShift(candles, bullish: bullish, sweepIndex: sweepIndex);
    if (shiftLevel == null) return null;

    // Gate 6 — the shift must be carried by a decisive candle.
    final pattern = _decisiveConfirmation(candles, lastIndex, bullish: bullish);
    if (pattern == CandlePattern.none) return null;

    final confluence = _isConfluenceZone(nearest, htfZones) ? ' + Confluence Zone' : '';
    return ExecutionTrigger(
      type: SetupType.htfRetest,
      zone: HtfZone(
        price: nearest.price,
        source: '${nearest.source} ($sweepLabel + MSS @ \$${shiftLevel.toStringAsFixed(2)}$confluence)',
      ),
      pattern: pattern,
      candleIndex: lastIndex,
      swingAnchor: swingAnchor,
      liquidityTarget: _findLiquidityTarget(candles, htfZones, entry: last.close, bullish: bullish),
    );
  }

  /// Liquidity-sweep detection: a recent swing low (or high, when [bullish]
  /// is false) that a later candle wicked through — taking the stops
  /// resting beyond it — before closing back on the original side. Shared
  /// (2026-09-18) by the HTF Retest Protocol above and IctEngine's
  /// Liquidity-Sweep Reversal path, so "a sweep" means one thing in this
  /// codebase; the returned [sweptExtreme] is what the Retest Protocol
  /// anchors its Stop Loss behind.
  ///
  /// Scans every qualifying sweep in the window rather than returning the
  /// first, and keeps the one that ran FURTHEST past its pivot — a stop
  /// placed behind a shallower sweep would sit inside a deeper one that
  /// already happened. [minSweepIndex] restricts which candles may count as
  /// the sweeping candle (the Retest Protocol requires the sweep to happen
  /// after the zone break; IctEngine leaves it at 0), while [lookback]
  /// bounds how old the swept PIVOT itself may be.
  ({Pivot pivot, int sweepIndex, double sweptExtreme})? findLiquiditySweep(
    List<Candle> candles, {
    required bool bullish,
    int lookback = AppConfig.liquiditySweepLookback,
    int minSweepIndex = 0,
  }) {
    final pivots = findPivots(candles);
    final cutoff = (candles.length - lookback).clamp(0, candles.length);
    ({Pivot pivot, int sweepIndex, double sweptExtreme})? deepest;

    for (final pivot in pivots) {
      if (pivot.type != (bullish ? PivotType.low : PivotType.high)) continue;
      if (pivot.index < cutoff) continue;
      for (int j = max(pivot.index + 1, minSweepIndex); j < candles.length; j++) {
        final c = candles[j];
        final wicked = bullish ? c.low < pivot.price : c.high > pivot.price;
        final closedBack = bullish ? c.close > pivot.price : c.close < pivot.price;
        if (!wicked || !closedBack) continue;
        final extreme = bullish ? c.low : c.high;
        final runsFurther = deepest == null ||
            (bullish ? extreme < deepest.sweptExtreme : extreme > deepest.sweptExtreme);
        if (runsFurther) {
          deepest = (pivot: pivot, sweepIndex: j, sweptExtreme: extreme);
        }
      }
    }
    return deepest;
  }

  /// The most recent candle in `[start, end]` that swept the zone price
  /// itself rather than a swing — [_isInstitutionalAbsorption]'s wick-
  /// through/body-back footprint — paired with the extreme its wick
  /// reached, for the same Stop Loss anchoring.
  ({double extreme, int index})? _findZoneSweep(
    List<Candle> candles,
    int start,
    int end,
    double zonePrice, {
    required bool bullish,
  }) {
    for (int i = end; i >= start; i--) {
      if (!_isInstitutionalAbsorption(candles[i], zonePrice, isBullish: bullish)) continue;
      return (extreme: bullish ? candles[i].low : candles[i].high, index: i);
    }
    return null;
  }

  /// Market Structure Shift / CHoCH: after liquidity was taken at
  /// [sweepIndex], the move is only confirmed once price closes beyond the
  /// swing that framed the leg INTO that sweep — for a bullish setup, the
  /// last swing high formed before the sweep candle. Returns that reference
  /// level (for the trigger's label) or null when it hasn't been taken out,
  /// or when no such swing exists yet.
  double? _findStructureShift(List<Candle> candles, {required bool bullish, required int sweepIndex}) {
    final wanted = bullish ? PivotType.high : PivotType.low;
    Pivot? reference;
    for (final pivot in findPivots(candles)) {
      if (pivot.type != wanted || pivot.index >= sweepIndex) continue;
      reference = pivot; // findPivots walks forward, so the last match is the most recent
    }
    if (reference == null) return null;

    final close = candles.last.close;
    final shifted = bullish ? close > reference.price : close < reference.price;
    return shifted ? reference.price : null;
  }

  /// The confirmation standard for a Market Structure Shift: displacement
  /// ([classifyMomentum]), an Engulfing, or a strong Absorption — in that
  /// order of preference. A Pinbar or Doji is deliberately NOT accepted
  /// here even though [classifyPattern] recognises it: a candle whose body
  /// barely reaches past the level it supposedly broke is a wick through
  /// structure, not a shift of it. Returns [CandlePattern.none] when the
  /// candle fails all three, or qualifies in the wrong direction.
  CandlePattern _decisiveConfirmation(List<Candle> candles, int index, {required bool bullish}) {
    final momentum = classifyMomentum(candles, index);
    if (momentum == (bullish ? CandlePattern.bullishMomentum : CandlePattern.bearishMomentum)) {
      return momentum;
    }
    final engulfing = classifyPattern(candles, index);
    if (engulfing == (bullish ? CandlePattern.bullishEngulfing : CandlePattern.bearishEngulfing)) {
      return engulfing;
    }
    final absorption = classifyStrongAbsorption(candles, index);
    if (absorption == (bullish ? CandlePattern.bullishAbsorption : CandlePattern.bearishAbsorption)) {
      return absorption;
    }
    return CandlePattern.none;
  }

  /// The next place price is genuinely expected to react on the way to
  /// profit: the NEAREST untapped swing high (or low, for a sell) or
  /// [HtfZone] ahead of [entry]. The nearest one is deliberately chosen
  /// over the most attractive — it is the first obstacle in the path, and
  /// pricing Take Profit past it would be betting the move clears a level
  /// this same engine treats as structure everywhere else. Null when
  /// nothing sits ahead of Entry, which leaves RiskEngine on its fixed
  /// [AppConfig.riskRewardRatio] multiple.
  double? _findLiquidityTarget(
    List<Candle> candles,
    List<HtfZone> zones, {
    required double entry,
    required bool bullish,
  }) {
    final wanted = bullish ? PivotType.high : PivotType.low;
    final ahead = <double>[
      for (final pivot in findPivots(candles))
        if (pivot.type == wanted) pivot.price,
      for (final zone in zones) zone.price,
    ].where((price) => bullish ? price > entry : price < entry).toList();

    if (ahead.isEmpty) return null;
    return ahead.reduce((a, b) => bullish ? min(a, b) : max(a, b));
  }

  /// Institutional Absorption / Strict Liquidity Sweep check (2026-09-10,
  /// High-Probability Gating): true only when [candle]'s WICK genuinely
  /// breaks [zonePrice] — trades strictly through it — while its BODY
  /// (both open and close) stays strictly on the opposite, "safe" side of
  /// it. That combination is the real footprint of a liquidity sweep being
  /// absorbed by the opposing side at the level: a bare touch, or a body
  /// that overlaps/crosses the zone itself, does not count. Since
  /// 2026-09-18 this is the HTF Retest Protocol's zone-sweep reading (see
  /// [_findZoneSweep]) — the fallback when no swing was swept — rather than
  /// a confirmation test applied to the entry candle on its own.
  bool _isInstitutionalAbsorption(Candle candle, double zonePrice, {required bool isBullish}) {
    if (isBullish) {
      // Wick swept below the zone (liquidity grab) and the body closed
      // back above it (absorption/rejection).
      return candle.low < zonePrice && candle.open > zonePrice && candle.close > zonePrice;
    }
    // Wick swept above the zone and the body closed back below it.
    return candle.high > zonePrice && candle.open < zonePrice && candle.close < zonePrice;
  }

  /// True when [zone] is corroborated by at least one OTHER independent
  /// [zones] entry within [AppConfig.confluenceZoneToleranceDollars] of it
  /// (2026-09-11) — e.g. a Trendline crossing right through a Support/
  /// Resistance level, or a 1H zone sitting almost exactly on a 4H one.
  /// Two or more independent structural findings agreeing on nearly the
  /// same price is a materially stronger signal than any single one alone.
  /// This used to earn such a zone a relaxed Path A eligibility; since
  /// 2026-09-18 the HTF Retest Protocol holds every zone to the same
  /// sequence, so confluence is reported as a quality tag on the fired
  /// trigger's label (visible in logs, notifications and Telegram) instead
  /// of waiving a requirement.
  bool _isConfluenceZone(HtfZone zone, List<HtfZone> zones) {
    for (final other in zones) {
      if (identical(other, zone)) continue;
      if (other.source == zone.source && other.price == zone.price) continue;
      if ((other.price - zone.price).abs() <= AppConfig.confluenceZoneToleranceDollars) return true;
    }
    return false;
  }

  // ---------------------------------------------------------------------
  // 6) ABSORPTION PATTERN CLASSIFIER
  // ---------------------------------------------------------------------
  // The standalone "15M Higher Low / Lower High Absorption" execution
  // strategy (SetupType.absorption15m) that used to live here — a
  // two-candle open/close relationship traded directly at any HTF zone —
  // was retired 2026-09-18, explicit request. [classifyStrongAbsorption]
  // below survives as a shared PATTERN classifier: the HTF Retest
  // Protocol's own confirmation check (see [_decisiveConfirmation]) and
  // ImpulseCorrectionEngine's Correction Termination Trigger both still
  // use it to recognise genuine Absorption candles, just no longer as an
  // independent path into a trade on its own.
  // ---------------------------------------------------------------------

  /// Absorption classifier + STRENGTH filter (2026-09-17, explicit
  /// request: skip the entry when the Absorption pattern fails or shows
  /// weakness). Returns [CandlePattern.none] both when the raw two-candle
  /// shape isn't there AND when it is there but weak — a weak/failed
  /// absorption is treated exactly like no absorption at all, so no setup
  /// is ever built from it.
  /// Thresholds: AppConfig.absorptionMinBodyDominance /
  /// absorptionMinBodyRatio / absorptionMaxOpposingWickRatio.
  CandlePattern classifyStrongAbsorption(List<Candle> candles, int index) {
    if (index < 1 || index >= candles.length) return CandlePattern.none;
    final curr = candles[index];
    final prev = candles[index - 1];

    final bool bullish;
    if (curr.isBullish && prev.isBearish && prev.close <= curr.open) {
      bullish = true;
    } else if (curr.isBearish && prev.isBullish && prev.close > curr.open) {
      bullish = false;
    } else {
      return CandlePattern.none;
    }

    // 1) Body dominance — the absorbing candle must be at least as big as
    //    the candle it claims to have absorbed.
    if (prev.bodySize > 0 &&
        curr.bodySize < prev.bodySize * AppConfig.absorptionMinBodyDominance) {
      return CandlePattern.none;
    }

    // 2) Conviction — mostly body, not a wide indecisive range.
    if (curr.range <= 0) return CandlePattern.none;
    if (curr.bodySize / curr.range < AppConfig.absorptionMinBodyRatio) {
      return CandlePattern.none;
    }

    // 3) Follow-through — the close must actually take out the absorbed
    //    candle's own origin, otherwise the absorption never completed.
    if (bullish ? curr.close <= prev.open : curr.close >= prev.open) {
      return CandlePattern.none;
    }

    // 4) Failure in real time — a large wick AGAINST the absorption means
    //    price was pushed straight back out of the level.
    final opposingWick = bullish ? curr.upperWick : curr.lowerWick;
    if (opposingWick / curr.range > AppConfig.absorptionMaxOpposingWickRatio) {
      return CandlePattern.none;
    }

    return bullish ? CandlePattern.bullishAbsorption : CandlePattern.bearishAbsorption;
  }

  /// Convenience: minimum/maximum helper used elsewhere.
  double roundTo(double v, int decimals) {
    final factor = pow(10, decimals);
    return (v * factor).round() / factor;
  }

  // ---------------------------------------------------------------------
  // 7) AVERAGE TRUE RANGE (2026-09-18, for BreakoutMomentumEngine)
  // ---------------------------------------------------------------------

  /// Wilder's Average True Range as of the LAST candle in [candles] — the
  /// standard smoothing every charting platform's ATR(period) uses (a
  /// plain SMA of True Range reacts far more sharply to a single outlier
  /// candle, which is exactly the noise this is meant to filter out).
  /// True Range needs a PREVIOUS close, so this needs [period] + 1
  /// candles; returns null when there aren't enough.
  double? averageTrueRange(List<Candle> candles, {int period = 14}) {
    if (candles.length < period + 1) return null;

    final trueRanges = <double>[];
    for (int i = 1; i < candles.length; i++) {
      final c = candles[i];
      final prevClose = candles[i - 1].close;
      trueRanges.add([c.high - c.low, (c.high - prevClose).abs(), (c.low - prevClose).abs()].reduce(max));
    }

    // Seed with a plain average of the first [period] true ranges, then
    // roll every later one in at Wilder's 1/period weight.
    var atr = trueRanges.take(period).reduce((a, b) => a + b) / period;
    for (int i = period; i < trueRanges.length; i++) {
      atr = (atr * (period - 1) + trueRanges[i]) / period;
    }
    return atr;
  }
}
