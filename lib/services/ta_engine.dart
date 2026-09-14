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
  /// that happens to close near its high/low). Used by findExecutionTrigger
  /// as the second (Momentum/Breakout) trigger path, independent of
  /// classifyPattern's Reversal/Retest path above.
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
  // 5) STRICT TOP-DOWN STRATEGY (DUAL-MODE SIGNAL ENGINE)
  //    a) buildHtfZones — structural S/R + trendlines from 15M/1H/4H ONLY
  //       (2026-09-10: 4H added). 1M/5M are never used to seed a new zone.
  //    b) findExecutionTrigger — the ONLY thing that can produce a setup:
  //       a 1M/5M price-action trigger — Reversal/Retest at one of those
  //       pre-identified HTF zones, OR a Momentum/Breakout expansion
  //       candle when no Reversal/Retest pattern exists. 5M is the primary
  //       execution timeframe; 1M is a same-cycle scalping fallback only
  //       tried when 5M finds nothing (see signal_checker.dart) — this
  //       method itself is fully timeframe-agnostic, operating on whatever
  //       candle list it's given.
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

  /// The ONLY entry point into a trade under the Strict Top-Down strategy:
  /// finds the nearest of [htfZones] to the current price, then tries TWO
  /// independent trigger paths there, in order —
  ///  a) Reversal/Retest (preferred): a Pinbar/Engulfing candle at the
  ///     zone, confirmed EITHER by genuine Institutional Absorption
  ///     (2026-09-10 High-Probability Gating) — the WICK breaks the zone's
  ///     exact price boundary while the BODY closes strictly back behind
  ///     it, see [_isInstitutionalAbsorption] — OR, when [nearest] is a
  ///     Confluence Zone (2026-09-11, see [_isConfluenceZone]: corroborated
  ///     by another independent zone very close to it, e.g. a Trendline
  ///     crossing a Support/Resistance), simply by price sitting within the
  ///     Interest Area — no wick penetration required there, since two+
  ///     independent structural findings agreeing is already strong enough
  ///     confirmation on its own. An ordinary single-source zone still
  ///     requires the full Institutional Absorption check.
  ///  b) Momentum/Breakout (fallback, only tried when (a) finds nothing): a
  ///     decisive, wide-bodied expansion candle in a clear direction (see
  ///     [classifyMomentum]) — no Pinbar/Engulfing required. Eligible when
  ///     price sits within AppConfig.interestZoneBufferDollars of [nearest]
  ///     — a flexible "Interest Area" (2026-09-09) — OR when this candle's
  ///     own high-low range crossed the zone price intrabar (Order Flow
  ///     allowance, 2026-09-09): a Momentum candle that spiked through the
  ///     level and closed meaningfully beyond the buffer is still a
  ///     genuine Order Flow confirmation. Its SL is anchored to the
  ///     breakout candle's OWN opposing wick rather than [nearest], since a
  ///     distant structural zone would blow up what should be a tight
  ///     momentum stop.
  /// Returns null when neither path finds a qualifying trigger, or when
  /// [htfZones]/[candles] are empty. [candles] is used *only* for these
  /// pattern checks — never to derive a new structural zone of their own —
  /// and this method is fully timeframe-agnostic: the caller passes
  /// whichever of 1M or 5M it wants checked (see signal_checker.dart, which
  /// tries 5M first and falls back to 1M scalping only when 5M finds
  /// nothing).
  ExecutionTrigger? findExecutionTrigger({
    required List<Candle> candles,
    required List<HtfZone> htfZones,
    int lookback = 15,
  }) {
    if (candles.isEmpty || htfZones.isEmpty) return null;
    final lastIndex = candles.length - 1;
    final lastCandle = candles[lastIndex];
    final lastPrice = lastCandle.close;

    final nearest = findNearestZone(htfZones, lastPrice);
    if (nearest == null) return null;
    final nearestDist = (lastPrice - nearest.price).abs();

    // Path A — Reversal/Retest: both trigger types require the SAME
    // confirming candle at the zone — a bare touch with no pattern is
    // never a trigger of either kind. What distinguishes Reversal from
    // Retest is the recent price history.
    final pattern = classifyPattern(candles, lastIndex);
    final isBullishPattern = pattern == CandlePattern.bullishPinbar || pattern == CandlePattern.bullishEngulfing;
    final isBearishPattern = pattern == CandlePattern.bearishPinbar || pattern == CandlePattern.bearishEngulfing;

    if (isBullishPattern || isBearishPattern) {
      final sweepConfirmed = _isInstitutionalAbsorption(lastCandle, nearest.price, isBullish: isBullishPattern);

      // Confluence Zone relaxation (2026-09-11 — "ليش لما يدق بالدعم او
      // المقاومة والتريند لاين ماعم تعطينا صفقات"): when [nearest] is
      // corroborated by at least one OTHER independent zone very close to
      // it (e.g. a Trendline overlapping a Support/Resistance, or 1H and
      // 4H agreeing) — see [_isConfluenceZone] — that's a materially
      // stronger level than any single-source zone, so a plain confirmed
      // Pinbar/Engulfing within the Interest Area is enough here; it does
      // NOT need the wick to also literally break the zone's exact price
      // the way a single-source zone still does. Ordinary, non-confluence
      // zones are completely unaffected — same strict sweepConfirmed-only
      // gate as before.
      final withinBuffer =
          nearestDist <= AppConfig.interestZoneBufferDollars + AppConfig.interestZoneToleranceDollars;
      final confluenceConfirmed = withinBuffer && _isConfluenceZone(nearest, htfZones);

      if (sweepConfirmed || confluenceConfirmed) {
        // Did price already close decisively through this exact zone within
        // the recent lookback window (before this candle)? If so, this
        // confirming candle is validating a retest of broken structure —
        // otherwise it's a fresh rejection the first time price reached it.
        final start = (lastIndex - lookback).clamp(0, lastIndex);
        final brokeRecently = _rangeHasClose(
          candles,
          start,
          lastIndex,
          (c) => (c.close - nearest.price).abs() > AppConfig.proximityThreshold,
        );

        final confirmationLabel =
            sweepConfirmed ? 'Liquidity Sweep — Institutional Absorption Confirmed' : 'Confluence Zone Confirmed';

        return ExecutionTrigger(
          type: brokeRecently ? SetupType.htfRetest : SetupType.htfReversal,
          zone: HtfZone(
            price: nearest.price,
            source: '${nearest.source} ($confirmationLabel)',
          ),
          pattern: pattern,
          candleIndex: lastIndex,
        );
      }
    }

    // Path B — Momentum/Breakout: no confirmed Reversal/Retest sweep, but
    // this candle may still show strong directional expansion on its own.
    // interestZoneToleranceDollars (2026-09-10 — "ليش اذا كانت فوق المجال
    // بـ10 بيب تلغي الصفقة؟"): a small extra flex margin on top of the main
    // buffer so a near-miss doesn't hard-reject an otherwise valid trigger.
    final withinInterestZone =
        nearestDist <= AppConfig.interestZoneBufferDollars + AppConfig.interestZoneToleranceDollars;
    final crossedZoneIntrabar = lastCandle.low <= nearest.price && lastCandle.high >= nearest.price;
    if (!withinInterestZone && !crossedZoneIntrabar) return null;

    // True only when eligibility came SOLELY from the penetration
    // allowance above (not the normal in-buffer touch) — used below to
    // visibly flag these as high-signal Order Flow confirmations wherever
    // zone.source is already displayed (logs, notifications, Telegram, the
    // zone-cooldown key), with no changes needed in any of those consumers.
    final orderFlowPenetration = !withinInterestZone && crossedZoneIntrabar;

    // The zone here is deliberately NOT [nearest] — a momentum entry's stop
    // belongs just beyond the breakout candle's own opposing wick, not at
    // a possibly-distant structural level (RiskEngine anchors SL to
    // zone.zonePrice, so a far zone would blow up the SL/TP distance).
    // [nearest] is preserved only as informational context in the label.
    final momentum = classifyMomentum(candles, lastIndex);
    if (momentum == CandlePattern.bullishMomentum || momentum == CandlePattern.bearishMomentum) {
      final isBullish = momentum == CandlePattern.bullishMomentum;
      final momentumZone = HtfZone(
        price: isBullish ? lastCandle.low : lastCandle.high,
        source: orderFlowPenetration
            ? 'Momentum Breakout (nearest structure: ${nearest.source} — Liquidity Sweep — Order Flow Confirmed)'
            : 'Momentum Breakout (nearest structure: ${nearest.source})',
      );
      return ExecutionTrigger(
        type: SetupType.momentumBreakout,
        zone: momentumZone,
        pattern: momentum,
        candleIndex: lastIndex,
      );
    }

    return null;
  }

  /// Institutional Absorption / Strict Liquidity Sweep check (2026-09-10,
  /// High-Probability Gating): true only when [candle]'s WICK genuinely
  /// breaks [zonePrice] — trades strictly through it — while its BODY
  /// (both open and close) stays strictly on the opposite, "safe" side of
  /// it. That combination is the real footprint of a liquidity sweep being
  /// absorbed by the opposing side at the level: a bare touch, or a body
  /// that overlaps/crosses the zone itself, does not count.
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
  /// same price is a materially stronger signal than any single one alone,
  /// which is what earns it the relaxed [findExecutionTrigger] Path A
  /// eligibility (plain confirmed pattern, no required wick penetration).
  bool _isConfluenceZone(HtfZone zone, List<HtfZone> zones) {
    for (final other in zones) {
      if (identical(other, zone)) continue;
      if (other.source == zone.source && other.price == zone.price) continue;
      if ((other.price - zone.price).abs() <= AppConfig.confluenceZoneToleranceDollars) return true;
    }
    return false;
  }

  bool _rangeHasClose(List<Candle> candles, int start, int end, bool Function(Candle) test) {
    for (int i = start; i < end; i++) {
      if (test(candles[i])) return true;
    }
    return false;
  }

  // ---------------------------------------------------------------------
  // 6) HIGHER LOW / LOWER HIGH ABSORPTION (15M-ONLY, 2026-09-10)
  // ---------------------------------------------------------------------
  /// A 15M-EXCLUSIVE execution pattern, structurally distinct from the
  /// 1M/5M Reversal/Retest and Momentum/Breakout paths above: it reads the
  /// relationship between the two most recent 15M candles rather than a
  /// single candle's own wick/body shape —
  /// Open-vs-prior-close relationship (2026-09-11, final revision — no
  /// low/high comparison at all anymore, purely about the gap, or lack of
  /// one, between the two candles' open/close):
  ///  - Bullish Absorption (BUY): the current 15M candle is bullish,
  ///    immediately follows a bearish 15M candle, and that PREVIOUS
  ///    candle's close is at or BELOW the current candle's own open — no
  ///    gap down between them (flat or gapped up) — "close الشمعة الحمراء
  ///    الاخيرة قبل الصعود اوطى من قيمة open او تساويها للشمعة الخضراء
  ///    الحالية".
  ///  - Bearish Absorption (SELL): the current 15M candle is bearish,
  ///    immediately follows a bullish 15M candle, and that PREVIOUS
  ///    candle's close is strictly ABOVE the current candle's own open —
  ///    a genuine gap down between them — "Close الشمعة الخضراء السابقة
  ///    اعلى من open الشمعة الحمراء الحالية".
  /// Either direction additionally requires the current candle's close to
  /// sit within AppConfig.interestZoneBufferDollars of the nearest
  /// [htfZones] entry — same Interest Area convention as the 1M/5M paths —
  /// since this pattern is still only ever traded AT a pre-identified HTF
  /// Key Zone, never in open air. [candleIndex] on the returned trigger is
  /// the CURRENT candle; RiskEngine anchors the Stop Loss to the PREVIOUS
  /// candle's own low/high (index - 1) per this pattern's definition, not
  /// to the zone or the current candle's wick.
  ///
  /// STRICTLY requires the "current" candle to have actually CLOSED
  /// (2026-09-10 fix): [candles15m]'s last element is frequently the
  /// still-forming bar in a live feed — its own close is just the latest
  /// tick, not a settled price, so evaluating the Higher-Low/Lower-High
  /// relationship (and pricing Entry off it) against it is unsound; the
  /// "low"/"high"/"close" being tested could still move for the rest of
  /// that 15-minute window. This is the one thing that makes this pattern
  /// different from the 1M/5M paths above, which intentionally react to
  /// the forming candle for fast confirmation — a 15-minute window left
  /// open is a much bigger risk window to price against. [candleIndex] on
  /// the returned trigger always refers to a closed candle as a result.
  /// Returns null when the last candle hasn't closed yet, when the
  /// two-candle relationship doesn't hold, when price isn't near a zone,
  /// or when [candles15m] has fewer than 2 candles / [htfZones] is empty.
  ExecutionTrigger? find15mAbsorptionTrigger({
    required List<Candle> candles15m,
    required List<HtfZone> htfZones,
  }) {
    if (candles15m.length < 2 || htfZones.isEmpty) return null;
    final lastIndex = candles15m.length - 1;
    final curr = candles15m[lastIndex];
    final prev = candles15m[lastIndex - 1];

    final candleCloseTime = curr.time.toUtc().add(const Duration(minutes: 15));
    if (DateTime.now().toUtc().isBefore(candleCloseTime)) return null;

    CandlePattern? pattern;
    if (curr.isBullish && prev.isBearish && prev.close <= curr.open) {
      pattern = CandlePattern.bullishAbsorption;
    } else if (curr.isBearish && prev.isBullish && prev.close > curr.open) {
      pattern = CandlePattern.bearishAbsorption;
    }
    if (pattern == null) return null;

    final nearest = findNearestZone(htfZones, curr.close);
    if (nearest == null) return null;
    final nearestDist = (curr.close - nearest.price).abs();
    if (nearestDist > AppConfig.interestZoneBufferDollars + AppConfig.interestZoneToleranceDollars) return null;

    return ExecutionTrigger(
      type: SetupType.absorption15m,
      zone: HtfZone(
        price: nearest.price,
        source: '${nearest.source} (15M Higher Low / Lower High Absorption)',
      ),
      pattern: pattern,
      candleIndex: lastIndex,
    );
  }

  /// Convenience: minimum/maximum helper used elsewhere.
  double roundTo(double v, int decimals) {
    final factor = pow(10, decimals);
    return (v * factor).round() / factor;
  }
}
