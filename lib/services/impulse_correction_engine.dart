import 'dart:math';

import '../config/app_config.dart';
import '../models/candle.dart';
import '../models/pivot.dart';
import 'ict_engine.dart';
import 'ta_engine.dart';

/// Result of scanning one entry-timeframe candle series for an ICI
/// trigger — same (trigger, candles, timeframe label) shape the other two
/// strategy tiers already use, so RiskEngine-style pricing/logging/
/// notifications need no special-casing in signal_checker.dart.
typedef IciTriggerResult = ({ExecutionTrigger trigger, List<Candle> candles, String timeframeLabel});

class _ImpulseLeg {
  final int startIndex; // first candle of the qualifying run
  final int endIndex; // last candle of the qualifying run (impulse extreme)
  final double startPrice; // the swing level the impulse departed from
  final double endPrice; // the impulse's own extreme (high for a bullish leg, low for a bearish one)
  final TradeDirection direction;
  const _ImpulseLeg({
    required this.startIndex,
    required this.endIndex,
    required this.startPrice,
    required this.endPrice,
    required this.direction,
  });
}

/// Impulse-Correction-Impulse (ICI) strategy layer, added 2026-09-13 as a
/// THIRD independent strategy alongside the legacy Strict Top-Down and ICT
/// strategies (see signal_checker.dart, which keeps this engine's debounce
/// state fully separate so it can fire its own setup in the same cycle
/// either of the other two also fires in).
///
/// Model: price moves in waves — a strong impulsive leg (Impulse 1,
/// >= [AppConfig.iciMinConsecutiveImpulseCandles] consecutive decisive
/// candles that break prior structure, a genuine BOS), then a corrective
/// pullback that retraces into the 50%-61.8% Fibonacci zone of that leg
/// (or instead touches a broken S/R/Trendline zone, Order Block, or Fair
/// Value Gap — the latter two reused from IctEngine rather than
/// re-detected here) while itself showing low-volatility, exhausted
/// candles. The moment the correction shows a genuine sign of ending —
/// a reversal confirmation candle, a sharp rejection wick, or a small
/// structural break back into Impulse 1's own direction — a fresh
/// continuation entry fires, back in that same direction (Impulse 2).
/// Unlike ICT, NO path here is exempt from HTF alignment: every setup
/// requires the 1H and 4H bias to actually agree with each other AND with
/// the trade direction.
class ImpulseCorrectionEngine {
  final TaEngine _ta;
  final IctEngine _ict;
  ImpulseCorrectionEngine({TaEngine? ta, IctEngine? ict})
      : _ta = ta ?? TaEngine(),
        _ict = ict ?? IctEngine();

  bool _isDecisive(Candle c) => c.range > 0 && (c.bodySize / c.range) >= AppConfig.iciMinImpulseBodyRatio;

  /// Finds the most recent qualifying Impulse 1 leg: a run of
  /// >= [AppConfig.iciMinConsecutiveImpulseCandles] consecutive, same-
  /// direction, decisive candles whose combined extreme breaks the most
  /// recent PRIOR swing pivot of the matching type (the BOS requirement).
  /// Scans backward from the most recent candle so a fresher impulse is
  /// always preferred over an older one still technically in range.
  _ImpulseLeg? _findImpulseLeg(List<Candle> candles, int lastIndex) {
    final minStart = (lastIndex - AppConfig.iciMaxImpulseAgeCandles).clamp(0, lastIndex);
    final pivots = _ta.findPivots(candles);

    // Leave room for >=1 correction candle plus the confirmation candle
    // after the impulse ends.
    for (int end = lastIndex - 2; end >= minStart + 1; end--) {
      if (!_isDecisive(candles[end]) || !_isDecisive(candles[end - 1])) continue;
      final isBullish = candles[end].isBullish;
      if (candles[end - 1].isBullish != isBullish) continue;

      var runStart = end - 1;
      while (runStart - 1 >= minStart && _isDecisive(candles[runStart - 1]) && candles[runStart - 1].isBullish == isBullish) {
        runStart--;
      }

      final direction = isBullish ? TradeDirection.buy : TradeDirection.sell;
      final priorPivots = pivots
          .where((p) => p.index < runStart && p.type == (isBullish ? PivotType.high : PivotType.low))
          .toList()
        ..sort((a, b) => a.index.compareTo(b.index));
      if (priorPivots.isEmpty) continue;
      final priorPivot = priorPivots.last;

      final runCandles = candles.sublist(runStart, end + 1);
      final impulseExtreme = isBullish
          ? runCandles.map((c) => c.high).reduce(max)
          : runCandles.map((c) => c.low).reduce(min);
      final brokeStructure = isBullish ? impulseExtreme > priorPivot.price : impulseExtreme < priorPivot.price;
      if (!brokeStructure) continue;

      final originWindowStart = max(priorPivot.index, runStart - 3);
      final originCandles = candles.sublist(originWindowStart, runStart + 1);
      final startPrice = isBullish
          ? originCandles.map((c) => c.low).reduce(min)
          : originCandles.map((c) => c.high).reduce(max);

      return _ImpulseLeg(startIndex: runStart, endIndex: end, startPrice: startPrice, endPrice: impulseExtreme, direction: direction);
    }
    return null;
  }

  bool _inFibZone(_ImpulseLeg impulse, Candle last) {
    final range = (impulse.endPrice - impulse.startPrice).abs();
    if (range <= 0) return false;
    if (impulse.direction == TradeDirection.buy) {
      final level50 = impulse.endPrice - range * AppConfig.iciFibRetracementMin;
      final level618 = impulse.endPrice - range * AppConfig.iciFibRetracementMax;
      return last.low <= level50 && last.low >= level618;
    } else {
      final level50 = impulse.endPrice + range * AppConfig.iciFibRetracementMin;
      final level618 = impulse.endPrice + range * AppConfig.iciFibRetracementMax;
      return last.high >= level50 && last.high <= level618;
    }
  }

  /// The correction-zone alternative to the Fibonacci band: touching a
  /// broken S/R/Trendline (from the shared [htfZones] pool) or an
  /// unmitigated Order Block / open Fair Value Gap — reused from IctEngine
  /// rather than re-detected here, so both strategies agree on what those
  /// mean.
  bool _touchesBrokenZoneOrObFvg(List<Candle> candles, Candle last, List<HtfZone> htfZones) {
    final nearest = _ta.findNearestZone(htfZones, last.close);
    if (nearest != null && (last.close - nearest.price).abs() <= AppConfig.interestZoneBufferDollars) {
      return true;
    }
    for (final ob in _ict.unmitigatedOrderBlocks(candles)) {
      if (last.low <= ob.high && last.high >= ob.low) return true;
    }
    for (final fvg in _ict.openFairValueGaps(candles)) {
      if (last.low <= fvg.high && last.high >= fvg.low) return true;
    }
    return false;
  }

  /// Same absorption definition as TaEngine.find15mAbsorptionTrigger, but
  /// generic to any timeframe (no "must be a closed 15M candle" gate),
  /// since ICI isn't 15M-exclusive.
  CandlePattern _classifyAbsorption(List<Candle> candles, int index) {
    if (index < 1) return CandlePattern.none;
    final curr = candles[index];
    final prev = candles[index - 1];
    if (curr.isBullish && prev.isBearish && prev.close <= curr.open) return CandlePattern.bullishAbsorption;
    if (curr.isBearish && prev.isBullish && prev.close > curr.open) return CandlePattern.bearishAbsorption;
    return CandlePattern.none;
  }

  /// Correction Termination Trigger #3 — a small structural break: the
  /// confirmation candle's close breaks back past the correction phase's
  /// OWN counter-bounce extreme, in Impulse 1's direction.
  bool _microBos(List<Candle> candles, int correctionStart, int lastIndex, bool isBullish) {
    double? extreme;
    for (int j = correctionStart; j < lastIndex; j++) {
      extreme = isBullish
          ? (extreme == null ? candles[j].high : max(extreme, candles[j].high))
          : (extreme == null ? candles[j].low : min(extreme, candles[j].low));
    }
    if (extreme == null) return false;
    final last = candles[lastIndex];
    return isBullish ? last.close > extreme : last.close < extreme;
  }

  /// The single entry point. Execution timeframe (2026-09-14,
  /// "completely disable Scalping strategies"): 15M ONLY —
  /// [candles1m]/[candles5m] were removed entirely (previously tried
  /// first, in that order, before 15M, until 2026-09-13's Multi-Timeframe
  /// Execution Expansion added 1M as a genuine candidate here too) rather
  /// than kept as unused parameters that always receive empty lists.
  /// Returns null when there's no HTF consensus at all, or when 15M has
  /// no qualifying Impulse-Correction-Impulse setup this cycle.
  IciTriggerResult? findTrigger({
    required List<Candle> candles15m,
    required List<Candle> candles1h,
    required List<Candle> candles4h,
    required List<HtfZone> htfZones,
  }) {
    final bias4h = _ict.structureBias(candles4h);
    final bias1h = _ict.structureBias(candles1h);
    final consensusBias = (bias4h != null && bias1h != null && bias4h == bias1h) ? bias4h : null;
    if (consensusBias == null) return null;

    for (final entry in [(candles15m, '15M')]) {
      final candles = entry.$1;
      final label = entry.$2;
      if (candles.length < 30) continue;
      final trigger = _tryImpulseCorrection(candles, htfZones, consensusBias);
      if (trigger != null) return (trigger: trigger, candles: candles, timeframeLabel: label);
    }
    return null;
  }

  ExecutionTrigger? _tryImpulseCorrection(List<Candle> candles, List<HtfZone> htfZones, TradeDirection consensusBias) {
    final lastIndex = candles.length - 1;
    final impulse = _findImpulseLeg(candles, lastIndex);
    if (impulse == null || impulse.direction != consensusBias) return null;

    final correctionStart = impulse.endIndex + 1;
    if (correctionStart >= lastIndex) return null; // need >=1 correction candle before the confirmation bar

    final isBullish = impulse.direction == TradeDirection.buy;

    // The correction must never break back past Impulse 1's own origin —
    // that would be a genuine reversal, not a pause.
    for (int j = correctionStart; j <= lastIndex; j++) {
      if (isBullish && candles[j].close < impulse.startPrice) return null;
      if (!isBullish && candles[j].close > impulse.startPrice) return null;
    }

    final last = candles[lastIndex];
    if (!_inFibZone(impulse, last) && !_touchesBrokenZoneOrObFvg(candles, last, htfZones)) return null;

    // Correction candles (excluding the confirmation bar itself) must show
    // low volatility / exhaustion.
    final correctionCandles = candles.sublist(correctionStart, lastIndex);
    if (correctionCandles.isEmpty) return null;
    final avgBodyRatio =
        correctionCandles.map((c) => c.range > 0 ? c.bodySize / c.range : 0.0).reduce((a, b) => a + b) /
            correctionCandles.length;
    if (avgBodyRatio > AppConfig.iciMaxCorrectionBodyRatio) return null;

    final pattern = _ta.classifyPattern(candles, lastIndex);
    final momentum = _ta.classifyMomentum(candles, lastIndex);
    final absorption = _classifyAbsorption(candles, lastIndex);

    final reversalCandle = isBullish
        ? (pattern == CandlePattern.bullishPinbar ||
            pattern == CandlePattern.bullishEngulfing ||
            absorption == CandlePattern.bullishAbsorption)
        : (pattern == CandlePattern.bearishPinbar ||
            pattern == CandlePattern.bearishEngulfing ||
            absorption == CandlePattern.bearishAbsorption);

    final rejectionWick = last.range > 0 &&
        (isBullish ? last.lowerWick / last.range : last.upperWick / last.range) >= AppConfig.iciMinRejectionWickRatio;

    final microBos = _microBos(candles, correctionStart, lastIndex, isBullish);

    if (!reversalCandle && !rejectionWick && !microBos) return null;

    final CandlePattern firedPattern;
    if (reversalCandle) {
      firedPattern = absorption != CandlePattern.none ? absorption : pattern;
    } else if (isBullish ? momentum == CandlePattern.bullishMomentum : momentum == CandlePattern.bearishMomentum) {
      firedPattern = momentum;
    } else {
      firedPattern = isBullish ? CandlePattern.bullishPinbar : CandlePattern.bearishPinbar;
    }

    // Stop-Loss anchor: the correction phase's own extreme (including the
    // confirmation candle's wick, since a V-shaped pullback's true low/high
    // often IS that final candle).
    final correctionExtreme = isBullish
        ? candles.sublist(correctionStart, lastIndex + 1).map((c) => c.low).reduce(min)
        : candles.sublist(correctionStart, lastIndex + 1).map((c) => c.high).reduce(max);

    final labelBits = <String>[
      if (reversalCandle) 'Reversal Candle',
      if (rejectionWick) 'Rejection Wick',
      if (microBos) 'Micro-BOS',
    ];

    return ExecutionTrigger(
      type: SetupType.impulseCorrectionContinuation,
      zone: HtfZone(price: correctionExtreme, source: 'Impulse-Correction-Impulse (${labelBits.join(" + ")})'),
      pattern: firedPattern,
      candleIndex: lastIndex,
    );
  }
}
