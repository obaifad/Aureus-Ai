import 'dart:math';

import '../config/app_config.dart';
import '../models/candle.dart';
import '../models/pivot.dart';
import 'ta_engine.dart';

/// Result of scanning one entry-timeframe candle series for an ICT/SMC
/// trigger — mirrors the (trigger, candles, timeframe label) tuple
/// SignalChecker already tracks manually for the legacy Strict Top-Down
/// strategy, so RiskEngine/logging/notifications can all be reused as-is.
typedef IctTriggerResult = ({ExecutionTrigger trigger, List<Candle> candles, String timeframeLabel});

/// A generic price zone (Order Block, Fair Value Gap, or Breaker Block) —
/// just a [low, high] band with the direction a retest of it should trade
/// and the candle index it formed at, used only to check "does the current
/// candle sit inside this, and has price already touched it before".
class PriceZone {
  final double high;
  final double low;
  final TradeDirection direction;
  final int formedIndex;
  const PriceZone({required this.high, required this.low, required this.direction, required this.formedIndex});
}

enum StructureEvent { none, bosBullish, bosBearish, chochBullish, chochBearish }

/// Short display label for GoldChartScreen's structural-event tags, e.g.
/// "BOS Bullish" / "CHoCH Bearish".
extension StructureEventLabel on StructureEvent {
  String? get label => switch (this) {
        StructureEvent.none => null,
        StructureEvent.bosBullish => 'BOS Bullish',
        StructureEvent.bosBearish => 'BOS Bearish',
        StructureEvent.chochBullish => 'CHoCH Bullish',
        StructureEvent.chochBearish => 'CHoCH Bearish',
      };
}

/// Smart-Money-Concepts (ICT) strategy layer, added 2026-09-12 as an
/// INDEPENDENT strategy alongside TaEngine's Strict Top-Down Dual-Mode
/// strategy (see signal_checker.dart, which keeps this engine's debounce
/// state separate so it can fire its own setup in the same cycle the
/// legacy strategy already did — neither blocks the other).
///
/// Bias comes from Break of Structure (continuation) / Change of Character
/// (reversal) on 4H+1H swing structure. Five independent trigger paths are
/// tried, in order — Liquidity-Sweep Reversal, Order Block retest, Fair
/// Value Gap fill, Breaker Block/Mitigation retest, then Trendline
/// continuation — against 15M (2026-09-14: the only execution timeframe
/// now that Scalping strategies are disabled; previously 5M then 1M were
/// tried first). The first one whose conditions are met wins, since ANY
/// one of them qualifying is enough by
/// design (no need to wait for every condition to line up perfectly).
/// Every path independently requires a genuine confirmation candle (a bare
/// touch/penetration of the zone is never enough) and Premium/Discount
/// alignment (buys only below the 1H equilibrium, sells only above it).
/// The four "with-trend" paths additionally require a clear, agreeing 4H+
/// 1H structure bias; the reversal path is exempt from that (it trades
/// AGAINST the immediate move by design) but instead requires all three of:
/// a strong higher-timeframe S/R zone, a recent liquidity sweep, and a
/// same-direction CHoCH/BOS with confirmation.
class IctEngine {
  final TaEngine _ta;
  IctEngine([TaEngine? ta]) : _ta = ta ?? TaEngine();

  // -----------------------------------------------------------------
  // Market Structure: BOS (continuation) / CHoCH (reversal) + HTF bias
  // -----------------------------------------------------------------

  /// Classifies whatever the LAST candle's close just did against the
  /// swing-pivot structure right before it: breaking beyond the most
  /// recent swing point in the direction structure was already moving is a
  /// Break of Structure (continuation); breaking beyond it AGAINST the
  /// prior structure is a Change of Character (the first sign of a
  /// reversal). Needs >= 2 swing highs AND >= 2 swing lows to have an
  /// opinion at all.
  StructureEvent lastStructureEvent(List<Candle> candles, {int lookback = 3}) {
    final pivots = _ta.findPivots(candles, lookback: lookback);
    final highs = pivots.where((p) => p.type == PivotType.high).toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    final lows = pivots.where((p) => p.type == PivotType.low).toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    if (highs.length < 2 || lows.length < 2) return StructureEvent.none;

    final lastHigh = highs.last, prevHigh = highs[highs.length - 2];
    final lastLow = lows.last, prevLow = lows[lows.length - 2];
    final priorBullish = lastLow.price > prevLow.price && lastHigh.price > prevHigh.price;
    final priorBearish = lastLow.price < prevLow.price && lastHigh.price < prevHigh.price;

    final lastClose = candles.last.close;
    if (lastClose > lastHigh.price) {
      return priorBearish ? StructureEvent.chochBullish : StructureEvent.bosBullish;
    }
    if (lastClose < lastLow.price) {
      return priorBullish ? StructureEvent.chochBearish : StructureEvent.bosBearish;
    }
    return StructureEvent.none;
  }

  /// Every historical structural break point in [candles] (2026-09-13 —
  /// GoldChartScreen's SMC Visualizer, which labels EVERY past BOS/CHoCH,
  /// not just what [lastStructureEvent] says about the very last candle).
  /// Walks forward candle-by-candle re-running the exact same break check
  /// [lastStructureEvent] does, but against the pivots KNOWN as of each
  /// index (never a later one, so this never look-aheads); each swing
  /// level is only reported once — the FIRST candle that closes past it —
  /// so a level price stays broken for several bars without spamming a
  /// label on every one of them.
  List<({int index, StructureEvent event})> structureEventHistory(List<Candle> candles, {int lookback = 3}) {
    final pivots = _ta.findPivots(candles, lookback: lookback);
    final highs = pivots.where((p) => p.type == PivotType.high).toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    final lows = pivots.where((p) => p.type == PivotType.low).toList()
      ..sort((a, b) => a.index.compareTo(b.index));

    final events = <({int index, StructureEvent event})>[];
    double? lastBrokenAbove;
    double? lastBrokenBelow;

    for (int i = lookback * 2 + 3; i < candles.length; i++) {
      final priorHighs = highs.where((h) => h.index < i).toList();
      final priorLows = lows.where((l) => l.index < i).toList();
      if (priorHighs.length < 2 || priorLows.length < 2) continue;

      final lastHigh = priorHighs.last, prevHigh = priorHighs[priorHighs.length - 2];
      final lastLow = priorLows.last, prevLow = priorLows[priorLows.length - 2];
      final priorBullish = lastLow.price > prevLow.price && lastHigh.price > prevHigh.price;
      final priorBearish = lastLow.price < prevLow.price && lastHigh.price < prevHigh.price;

      final close = candles[i].close;
      if (close > lastHigh.price) {
        if (lastBrokenAbove == lastHigh.price) continue;
        lastBrokenAbove = lastHigh.price;
        events.add((index: i, event: priorBearish ? StructureEvent.chochBullish : StructureEvent.bosBullish));
      } else if (close < lastLow.price) {
        if (lastBrokenBelow == lastLow.price) continue;
        lastBrokenBelow = lastLow.price;
        events.add((index: i, event: priorBullish ? StructureEvent.chochBearish : StructureEvent.bosBearish));
      }
    }
    return events;
  }

  /// Overall directional bias from swing structure alone — higher-highs +
  /// higher-lows is bullish, lower-highs + lower-lows is bearish. Used on
  /// 4H and 1H per the spec ("الاتجاه العام... عبر BOS/CHoCH على الفريمات
  /// الكبيرة"). Null when structure is choppy/mixed, or there isn't enough
  /// pivot history yet.
  TradeDirection? structureBias(List<Candle> candles, {int lookback = 3}) {
    final pivots = _ta.findPivots(candles, lookback: lookback);
    final highs = pivots.where((p) => p.type == PivotType.high).toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    final lows = pivots.where((p) => p.type == PivotType.low).toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    if (highs.length < 2 || lows.length < 2) return null;
    final lastHigh = highs.last, prevHigh = highs[highs.length - 2];
    final lastLow = lows.last, prevLow = lows[lows.length - 2];
    if (lastLow.price > prevLow.price && lastHigh.price > prevHigh.price) return TradeDirection.buy;
    if (lastLow.price < prevLow.price && lastHigh.price < prevHigh.price) return TradeDirection.sell;
    return null;
  }

  // -----------------------------------------------------------------
  // Premium / Discount
  // -----------------------------------------------------------------

  /// Midpoint of the recent 1H dealing range (last [AppConfig.
  /// ictEquilibriumWindow] candles) — price above it is "Premium" (sell
  /// zone per the spec), below it "Discount" (buy zone).
  double? equilibrium(List<Candle> candles1h) {
    if (candles1h.isEmpty) return null;
    const window = AppConfig.ictEquilibriumWindow;
    final recent = candles1h.length > window ? candles1h.sublist(candles1h.length - window) : candles1h;
    final high = recent.map((c) => c.high).reduce(max);
    final low = recent.map((c) => c.low).reduce(min);
    return (high + low) / 2;
  }

  bool _allowedByPremiumDiscount(TradeDirection direction, double price, double? eq) {
    if (eq == null) return true; // not enough 1H history yet — don't block on it
    return direction == TradeDirection.buy ? price < eq : price > eq;
  }

  // -----------------------------------------------------------------
  // Liquidity sweeps
  // -----------------------------------------------------------------

  /// True when a recent swing low was wicked through (liquidity grabbed
  /// below it) and price has already closed back above it — the setup for
  /// a bullish reversal. Symmetric (swing high / close back below) for a
  /// bearish reversal when [bullish] is false.
  bool _sweptLiquidityRecently(List<Candle> candles, {required bool bullish}) {
    final pivots = _ta.findPivots(candles);
    final relevant = pivots.where((p) => p.type == (bullish ? PivotType.low : PivotType.high));
    final cutoff = (candles.length - AppConfig.ictLiquiditySweepLookback).clamp(0, candles.length);
    for (final pivot in relevant) {
      if (pivot.index < cutoff) continue;
      for (int j = pivot.index + 1; j < candles.length; j++) {
        final c = candles[j];
        final wicked = bullish ? c.low < pivot.price : c.high > pivot.price;
        final closedBack = bullish ? c.close > pivot.price : c.close < pivot.price;
        if (wicked && closedBack) return true;
      }
    }
    return false;
  }

  // -----------------------------------------------------------------
  // Order Blocks — the last opposite-direction candle immediately before a
  // genuine momentum/expansion move (TaEngine.classifyMomentum).
  // -----------------------------------------------------------------

  /// Only zones untouched since they formed are returned (no candle
  /// between formation and the one just before [candles].last dipped back
  /// into the zone) — the spec requires the zone be "جديدة وغير ملموسة
  /// سابقا". Public (2026-09-13) so ImpulseCorrectionEngine can reuse the
  /// exact same Order Block detection for its own "touching a broken S/R /
  /// FVG / Order Block" correction-zone check, instead of duplicating it.
  List<PriceZone> unmitigatedOrderBlocks(List<Candle> candles) {
    final zones = <PriceZone>[];
    final lastIndex = candles.length - 1;
    final start = (lastIndex - AppConfig.ictZoneMaxAgeCandles).clamp(1, lastIndex);
    for (int i = start; i < lastIndex; i++) {
      final momentum = _ta.classifyMomentum(candles, i);
      if (momentum != CandlePattern.bullishMomentum && momentum != CandlePattern.bearishMomentum) continue;

      final obIndex = i - 1;
      if (obIndex < 0) continue;
      final obCandle = candles[obIndex];
      final isBullishOb = momentum == CandlePattern.bullishMomentum && obCandle.isBearish;
      final isBearishOb = momentum == CandlePattern.bearishMomentum && obCandle.isBullish;
      if (!isBullishOb && !isBearishOb) continue;

      var touchedBefore = false;
      for (int j = obIndex + 1; j < lastIndex; j++) {
        if (candles[j].low <= obCandle.high && candles[j].high >= obCandle.low) {
          touchedBefore = true;
          break;
        }
      }
      if (touchedBefore) continue;

      zones.add(PriceZone(
        high: obCandle.high,
        low: obCandle.low,
        direction: isBullishOb ? TradeDirection.buy : TradeDirection.sell,
        formedIndex: obIndex,
      ));
    }
    return zones;
  }

  // -----------------------------------------------------------------
  // Fair Value Gaps — classic 3-candle imbalance (gap between candle[i-2]
  // and candle[i], with candle[i-1] the impulse candle in between).
  // -----------------------------------------------------------------

  /// Public (2026-09-13) for the same reason as [unmitigatedOrderBlocks].
  List<PriceZone> openFairValueGaps(List<Candle> candles) {
    final zones = <PriceZone>[];
    final lastIndex = candles.length - 1;
    final start = (lastIndex - AppConfig.ictZoneMaxAgeCandles).clamp(2, lastIndex);
    for (int i = start; i < lastIndex; i++) {
      final left = candles[i - 2];
      final right = candles[i];

      double top, bottom;
      TradeDirection direction;
      if (right.low > left.high) {
        bottom = left.high;
        top = right.low;
        direction = TradeDirection.buy;
      } else if (right.high < left.low) {
        bottom = right.high;
        top = left.low;
        direction = TradeDirection.sell;
      } else {
        continue;
      }

      // Fully filled (price already traded clean through the far side)
      // retires the gap; a PARTIAL fill is exactly the retest opportunity
      // this method looks for, so it's left in the returned list.
      var fullyFilled = false;
      for (int j = i + 1; j < lastIndex; j++) {
        if (direction == TradeDirection.buy && candles[j].close < bottom) {
          fullyFilled = true;
          break;
        }
        if (direction == TradeDirection.sell && candles[j].close > top) {
          fullyFilled = true;
          break;
        }
      }
      if (fullyFilled) continue;

      zones.add(PriceZone(high: top, low: bottom, direction: direction, formedIndex: i));
    }
    return zones;
  }

  // -----------------------------------------------------------------
  // Breaker Blocks — an Order Block that later failed (price closed all
  // the way through its far side) flips into a zone that trades in the
  // OPPOSITE direction on retest. Also stands in for plain "Mitigation" of
  // a corrected zone, per the spec's "الـBreaker Block والـMitigation
  // كعناصر اضافية... عند اعادة اختبار مناطق تم كسرها او تصحيحها".
  // -----------------------------------------------------------------

  List<PriceZone> _breakerBlocks(List<Candle> candles) {
    final breakers = <PriceZone>[];
    final lastIndex = candles.length - 1;
    final start = (lastIndex - AppConfig.ictZoneMaxAgeCandles).clamp(1, lastIndex);
    for (int i = start; i < lastIndex; i++) {
      final momentum = _ta.classifyMomentum(candles, i);
      if (momentum != CandlePattern.bullishMomentum && momentum != CandlePattern.bearishMomentum) continue;

      final obIndex = i - 1;
      if (obIndex < 0) continue;
      final obCandle = candles[obIndex];
      final wasBullishOb = obCandle.isBearish;
      final wasBearishOb = obCandle.isBullish;
      if (!wasBullishOb && !wasBearishOb) continue;

      var broken = false;
      for (int j = obIndex + 1; j < lastIndex; j++) {
        if (wasBullishOb && candles[j].close < obCandle.low) {
          broken = true;
          break;
        }
        if (wasBearishOb && candles[j].close > obCandle.high) {
          broken = true;
          break;
        }
      }
      if (!broken) continue;

      breakers.add(PriceZone(
        high: obCandle.high,
        low: obCandle.low,
        direction: wasBullishOb ? TradeDirection.sell : TradeDirection.buy,
        formedIndex: obIndex,
      ));
    }
    return breakers;
  }

  // -----------------------------------------------------------------
  // Session filter — the caller (SignalChecker) is the one that applies
  // the "unless the signal is very strong" score-based bypass, since that
  // needs the setup's final Confluence Score, computed after this engine
  // returns a trigger.
  // -----------------------------------------------------------------
  bool isHighLiquiditySession(DateTime utcNow) {
    final h = utcNow.hour;
    final asian = h >= AppConfig.asianSessionStartUtc && h < AppConfig.asianSessionEndUtc;
    final london = h >= AppConfig.londonSessionStartUtc && h < AppConfig.londonSessionEndUtc;
    final newYork = h >= AppConfig.newYorkSessionStartUtc && h < AppConfig.newYorkSessionEndUtc;
    return asian || london || newYork;
  }

  bool _confirms(CandlePattern pattern, TradeDirection direction) {
    const bullish = {CandlePattern.bullishPinbar, CandlePattern.bullishEngulfing, CandlePattern.bullishAbsorption};
    const bearish = {CandlePattern.bearishPinbar, CandlePattern.bearishEngulfing, CandlePattern.bearishAbsorption};
    return direction == TradeDirection.buy ? bullish.contains(pattern) : bearish.contains(pattern);
  }

  /// The single entry point — see the class doc for the full priority
  /// order and gating rules. Tries 15M only (2026-09-14 — Scalping
  /// strategies disabled; 5M/1M were tried first before that). Returns
  /// null when none of the five paths qualifies.
  /// Execution timeframe (2026-09-14, "completely disable Scalping
  /// strategies"): 15M ONLY — [candles1m]/[candles5m] were removed
  /// entirely (previously tried first, in that order, before 15M) rather
  /// than kept as unused parameters that always receive empty lists.
  IctTriggerResult? findTrigger({
    required List<Candle> candles15m,
    required List<Candle> candles1h,
    required List<Candle> candles4h,
    required List<HtfZone> htfZones,
  }) {
    final bias4h = structureBias(candles4h);
    final bias1h = structureBias(candles1h);
    final htfBias = (bias4h != null && bias4h == bias1h) ? bias4h : null;
    final eq = equilibrium(candles1h);

    for (final entry in [(candles15m, '15M')]) {
      final candles = entry.$1;
      final label = entry.$2;
      if (candles.length < 20) continue;

      final lastIndex = candles.length - 1;
      final last = candles[lastIndex];
      final pattern = _ta.classifyPattern(candles, lastIndex);

      final trigger = _tryLiquiditySweepReversal(candles, lastIndex, last, pattern, htfZones, eq) ??
          _tryZoneRetest(candles, lastIndex, last, pattern, htfBias, eq, unmitigatedOrderBlocks(candles),
              SetupType.ictOrderBlock, 'Order Block') ??
          _tryZoneRetest(candles, lastIndex, last, pattern, htfBias, eq, openFairValueGaps(candles),
              SetupType.ictFairValueGap, 'Fair Value Gap') ??
          _tryZoneRetest(candles, lastIndex, last, pattern, htfBias, eq, _breakerBlocks(candles),
              SetupType.ictBreakerBlock, 'Breaker Block / Mitigation') ??
          _tryTrendlineContinuation(candles, lastIndex, last, pattern, htfBias, eq, htfZones);

      if (trigger != null) {
        return (trigger: trigger, candles: candles, timeframeLabel: label);
      }
    }
    return null;
  }

  ExecutionTrigger? _tryLiquiditySweepReversal(
    List<Candle> candles,
    int lastIndex,
    Candle last,
    CandlePattern pattern,
    List<HtfZone> htfZones,
    double? eq,
  ) {
    for (final bullish in [true, false]) {
      final direction = bullish ? TradeDirection.buy : TradeDirection.sell;
      if (!_confirms(pattern, direction)) continue;
      if (!_allowedByPremiumDiscount(direction, last.close, eq)) continue;

      // Condition 1 — a strong S/R from a HIGHER timeframe (1H/4H only;
      // an ordinary 15M zone doesn't qualify as "قوية من فريم أعلى" here).
      final nearest = _ta.findNearestZone(htfZones, last.close);
      if (nearest == null) continue;
      if (!nearest.source.startsWith('1H') && !nearest.source.startsWith('4H')) continue;
      final dist = (last.close - nearest.price).abs();
      if (dist > AppConfig.interestZoneBufferDollars + AppConfig.interestZoneToleranceDollars) continue;

      // Condition 2 — liquidity was actually taken first.
      if (!_sweptLiquidityRecently(candles, bullish: bullish)) continue;

      // Condition 3 — a same-direction CHoCH/BOS right here, WITH the
      // confirmation candle already required above.
      final event = lastStructureEvent(candles);
      final matches = bullish
          ? event == StructureEvent.chochBullish || event == StructureEvent.bosBullish
          : event == StructureEvent.chochBearish || event == StructureEvent.bosBearish;
      if (!matches) continue;

      return ExecutionTrigger(
        type: SetupType.ictLiquiditySweepReversal,
        zone: HtfZone(
          price: bullish ? last.low : last.high,
          source: '${nearest.source} (Liquidity Sweep + '
              '${event == StructureEvent.chochBullish || event == StructureEvent.chochBearish ? "CHoCH" : "BOS"} Reversal)',
        ),
        pattern: pattern,
        candleIndex: lastIndex,
      );
    }
    return null;
  }

  /// Shared retest logic for Order Blocks, Fair Value Gaps, and Breaker
  /// Blocks — all three are just "a zone the current candle now sits
  /// inside, retested for the first time, with a matching confirmation
  /// candle" once formed, they only differ in HOW the zone was built.
  ExecutionTrigger? _tryZoneRetest(
    List<Candle> candles,
    int lastIndex,
    Candle last,
    CandlePattern pattern,
    TradeDirection? htfBias,
    double? eq,
    List<PriceZone> zones,
    SetupType setupType,
    String label,
  ) {
    if (htfBias == null) return null;
    if (!_confirms(pattern, htfBias)) return null;
    if (!_allowedByPremiumDiscount(htfBias, last.close, eq)) return null;

    for (final z in zones) {
      if (z.direction != htfBias) continue;
      if (z.formedIndex >= lastIndex) continue;
      final touchesNow = last.low <= z.high && last.high >= z.low;
      if (!touchesNow) continue;

      return ExecutionTrigger(
        type: setupType,
        zone: HtfZone(
          price: htfBias == TradeDirection.buy ? z.low : z.high,
          source: '$label (${htfBias == TradeDirection.buy ? "bullish" : "bearish"})',
        ),
        pattern: pattern,
        candleIndex: lastIndex,
      );
    }
    return null;
  }

  ExecutionTrigger? _tryTrendlineContinuation(
    List<Candle> candles,
    int lastIndex,
    Candle last,
    CandlePattern pattern,
    TradeDirection? htfBias,
    double? eq,
    List<HtfZone> htfZones,
  ) {
    if (htfBias == null) return null;
    if (!_confirms(pattern, htfBias)) return null;
    if (!_allowedByPremiumDiscount(htfBias, last.close, eq)) return null;

    final pivots = _ta.findPivots(candles);
    final trendlines = _ta.buildTrendlines(pivots);
    for (final line in trendlines) {
      final direction = line.isAscending ? TradeDirection.buy : TradeDirection.sell;
      if (direction != htfBias) continue;

      final linePrice = line.priceAt(lastIndex);
      final dist = (last.close - linePrice).abs();
      if (dist > AppConfig.interestZoneBufferDollars) continue;

      // "ولم يكن هناك دعم او مقاومة قريب" — only take the trendline touch
      // when no OTHER (non-trendline) HTF zone already covers this price.
      final crowded = htfZones.any(
        (z) => !z.source.contains('Trendline') && (z.price - last.close).abs() <= AppConfig.interestZoneBufferDollars,
      );
      if (crowded) continue;

      return ExecutionTrigger(
        type: SetupType.ictTrendlineContinuation,
        zone: HtfZone(price: linePrice, source: 'Trendline Continuation (${line.isAscending ? "ascending" : "descending"})'),
        pattern: pattern,
        candleIndex: lastIndex,
      );
    }
    return null;
  }
}
