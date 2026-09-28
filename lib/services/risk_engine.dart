import 'dart:math';

import '../config/app_config.dart';
import '../models/candle.dart';
import '../models/pivot.dart';
import '../models/trade_setup.dart';

/// Turns a confirmed setup zone + candlestick pattern into a fully priced
/// TradeSetup. Risk:Reward is a strict [AppConfig.riskRewardRatio] on EVERY
/// path (2026-09-24, explicit request: "والتيك بروفيت لكل الصفقات 1.8") —
/// including the HTF Retest Protocol, which until then priced its Take
/// Profit AT the trigger's own [SetupZone.liquidityTarget] and accepted
/// whatever ratio that structure happened to pay.
class RiskEngine {
  /// Injectable clock (2026-09-25) so a historical replay stamps
  /// [TradeSetup.detectedAt] with the SIMULATED time — outcome tracking
  /// ignores every candle from before a setup's own detection time, so a
  /// wall-clock stamp would make a replayed trade unresolvable. Defaults to
  /// the real clock; production behaviour is unchanged.
  final DateTime Function() _clock;

  RiskEngine({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  TradeSetup? buildTradeSetup({
    required List<Candle> candles,
    required SetupZone zone,
    required CandlePattern pattern,
    required String timeframeLabel,
  }) {
    final direction = _directionFor(pattern);
    if (direction == null) return null;

    final confirmationCandle = candles[zone.candleIndex];
    final entry = confirmationCandle.close;

    // 15M HIGHER LOW / LOWER HIGH ABSORPTION (2026-09-10): SL is anchored
    // to the PREVIOUS candle's own low/high — per this pattern's own
    // definition, the level that just got absorbed — not to the current
    // (confirmation) candle's wick or the zone line at all.
    final isAbsorption = pattern == CandlePattern.bullishAbsorption || pattern == CandlePattern.bearishAbsorption;
    final prevIndex = zone.candleIndex - 1;
    final prevCandle = prevIndex >= 0 ? candles[prevIndex] : null;

    // 1M is ONLY a confirmation timeframe (2026-09-11 — "الدقيقة استعملو
    // فقط لتاكيد الدخول على فريم أكبر"): a 1M candle's own wick is too
    // small to size real risk against on its own — Rule 1's minimum-SL
    // floor used to paper over that, but removing that floor (2026-09-10)
    // means 1M setups need to size off the actual larger-timeframe
    // opportunity instead, same as 5M. So 1M and 5M now share the exact
    // same zone-aware anchor below: anchored to zone.zonePrice (not
    // srLevel.price) so this works identically for every SetupType — a
    // pure trendline bounce has no srLevel, and a breakout&retest may be
    // trendline- or S/R-based. The buffer is applied once when computing
    // the zone-side candidate, then again against whichever of {wick,
    // zone-side} wins, giving extra room beyond a bare S/R touch.
    // HTF Retest Protocol (2026-09-18): the trigger hands over the extreme
    // the liquidity sweep actually reached, and the Stop Loss goes behind
    // THAT rather than behind the zone boundary — the whole point of the
    // sweep is that price traded past the level to take the stops sitting
    // there, so a stop at the zone is inside the move that just happened.
    // The confirmation/previous wick anchor still applies alongside it
    // (whichever sits further out wins); only the zone-side candidate is
    // dropped for these setups.
    final swingAnchor = zone.swingAnchor;

    double stopLoss;
    if (direction == TradeDirection.buy) {
      if (isAbsorption) {
        stopLoss = prevCandle!.low - AppConfig.slBufferDollars;
      } else if (swingAnchor != null) {
        final outerWick = prevCandle != null
            ? [confirmationCandle.low, prevCandle.low].reduce((a, b) => a < b ? a : b)
            : confirmationCandle.low;
        stopLoss = [outerWick, swingAnchor].reduce((a, b) => a < b ? a : b) - AppConfig.slBufferDollars;
      } else {
        // Structural Wick Anchor (2026-09-15, explicit request): a
        // Reversal/Retest SL anchored to ONLY the confirmation candle's
        // own wick was getting clipped by a normal retest wick that
        // dipped a little past it but never actually broke the real
        // recent swing low — the PREVIOUS candle's own low, which the
        // confirmation candle (by definition of a reversal pattern) may
        // sit well above. Anchoring to the lower of the two — same idea
        // as the Absorption path above, just non-exclusive — means the
        // SL only breaks on a genuine invalidation of the swing, not a
        // wick that only pierced this one candle's shallower low.
        final outerWick = prevCandle != null
            ? [confirmationCandle.low, prevCandle.low].reduce((a, b) => a < b ? a : b)
            : confirmationCandle.low;
        final belowZone = zone.zonePrice - AppConfig.slBufferDollars;
        stopLoss = [outerWick, belowZone].reduce((a, b) => a < b ? a : b) -
            AppConfig.slBufferDollars;
      }
    } else {
      if (isAbsorption) {
        stopLoss = prevCandle!.high + AppConfig.slBufferDollars;
      } else if (swingAnchor != null) {
        final outerWick = prevCandle != null
            ? [confirmationCandle.high, prevCandle.high].reduce((a, b) => a > b ? a : b)
            : confirmationCandle.high;
        stopLoss = [outerWick, swingAnchor].reduce((a, b) => a > b ? a : b) + AppConfig.slBufferDollars;
      } else {
        // Mirror of the BUY-side Structural Wick Anchor above.
        final outerWick = prevCandle != null
            ? [confirmationCandle.high, prevCandle.high].reduce((a, b) => a > b ? a : b)
            : confirmationCandle.high;
        final aboveZone = zone.zonePrice + AppConfig.slBufferDollars;
        stopLoss = [outerWick, aboveZone].reduce((a, b) => a > b ? a : b) +
            AppConfig.slBufferDollars;
      }
    }

    final riskDistance = (entry - stopLoss).abs();
    if (riskDistance <= 0) return null;

    // No fixed minimum SL floor (2026-09-10, removed per explicit request:
    // "لا اريد اعتماد قيمة بيبات ثابتة للصفقات... سوف اقوم بتغير اللوت").
    // The Stop Loss stays exactly at whatever the structural distance
    // above computed — the user sizes their own position (lot) to the
    // actual pip distance rather than the system forcing a fixed-dollar
    // floor onto the SL itself, which used to widen tight-but-genuinely-
    // organic stops (and correlated with weaker setups when it kicked in).
    // slWasClamped is always false now — kept on TradeSetup only so old
    // persisted signal history JSON still deserializes.
    const slWasClamped = false;

    // Take Profit is the fixed [AppConfig.riskRewardRatio] multiple of the
    // risk on every path (2026-09-24, explicit request — "التيك بروفيت لكل
    // الصفقات 1.8"). This REPLACED the HTF Retest Protocol's structural
    // target (2026-09-18): that path used to price TP at the trigger's own
    // [SetupZone.liquidityTarget] — the next untapped swing/HTF level —
    // and take whatever ratio the structure paid, which meant two tiers
    // could hold two different targets at once. One multiple across every
    // tier is now the rule; note the trade-off it accepts: a 1.8R target
    // can now land just BEYOND a real liquidity level that price is likely
    // to react at, where the old behaviour would have banked it just
    // short. [SetupZone.liquidityTarget] is still computed and carried
    // (TaEngine._findLiquidityTarget) so this is a one-line change to
    // revert, and so the zone data stays truthful for anything else
    // reading it.
    final takeProfit = direction == TradeDirection.buy
        ? entry + (AppConfig.riskRewardRatio * riskDistance)
        : entry - (AppConfig.riskRewardRatio * riskDistance);

    return TradeSetup(
      symbol: AppConfig.symbol,
      direction: direction,
      timeframeLabel: timeframeLabel,
      setupType: zone.type,
      entry: _round(entry),
      stopLoss: _round(stopLoss),
      takeProfit: _round(takeProfit),
      pattern: pattern,
      detectedAt: _clock().toUtc(),
      slWasClamped: slWasClamped,
    );
  }

  /// The Impulse-Correction-Impulse tier's dynamic Stop Loss distance, in
  /// pips (2026-09-24, explicit request — replaced its fixed $1.50 floor):
  ///
  ///   max(structure, [AppConfig.iciSlAtrMultiplier] x [atr],
  ///       [AppConfig.iciMinStopLossPips])
  ///
  /// Only ever WIDENS: [structureSlPips] — the organic distance past the
  /// correction's own extreme that RiskEngine.buildTradeSetup already
  /// priced — wins whenever it is the widest of the three. Pass a null
  /// [atr] (not enough candles to compute ATR(14) yet) to drop that term.
  ///
  /// Kept here beside [calculateLotSize] on purpose: the two are two halves
  /// of the same risk decision. Widening the stop here automatically shrinks
  /// the position there, because the lot is sized from the SAME distance —
  /// so the account-level risk cap holds no matter which term won.
  double iciStopLossPips({required double structureSlPips, double? atr}) {
    final atrSlPips = atr == null ? 0.0 : (atr * AppConfig.iciSlAtrMultiplier) / TradeSetup.dollarsPerPip;
    return [structureSlPips, atrSlPips, AppConfig.iciMinStopLossPips].reduce(max);
  }

  /// Dynamic Position Sizing (Institutional Risk Management, 2026-09-20):
  /// converts a live account [equity] snapshot + this setup's own
  /// structural risk distance ([stopLossDollars], i.e. [TradeSetup.
  /// riskDollars]) into a broker-safe lot size that risks at most
  /// [riskPercent]% of the account on this ONE trade if its Stop Loss is
  /// hit — replacing any notion of a static/fixed lot. Rounded DOWN to
  /// [AppConfig.lotStep] (never up — rounding up would silently risk more
  /// than the configured cap) and clamped to [AppConfig.minLotSize] /
  /// [AppConfig.maxLotSize].
  ///
  /// $/pip for one lot = contract size (oz) x [TradeSetup.dollarsPerPip] —
  /// e.g. the standard 100oz XAUUSD contract moves $10/pip per lot. Lot
  /// size = risk amount / (SL distance in pips x $/pip per lot).
  double calculateLotSize({
    required double equity,
    required double stopLossDollars,
    double? riskPercent,
  }) {
    if (equity <= 0 || stopLossDollars <= 0) return AppConfig.minLotSize;

    final riskAmount = equity * ((riskPercent ?? AppConfig.riskPercentPerTrade) / 100.0);
    final pipValuePerLot = AppConfig.xauContractSize * TradeSetup.dollarsPerPip;
    final slPips = stopLossDollars / TradeSetup.dollarsPerPip;
    if (pipValuePerLot <= 0 || slPips <= 0) return AppConfig.minLotSize;

    final rawLot = riskAmount / (slPips * pipValuePerLot);
    final steppedLot = (rawLot / AppConfig.lotStep).floor() * AppConfig.lotStep;
    final clamped = steppedLot.clamp(AppConfig.minLotSize, AppConfig.maxLotSize);
    return double.parse(clamped.toStringAsFixed(2));
  }

  TradeDirection? _directionFor(CandlePattern pattern) {
    switch (pattern) {
      case CandlePattern.bullishPinbar:
      case CandlePattern.bullishEngulfing:
      case CandlePattern.bullishMomentum:
      case CandlePattern.bullishAbsorption:
        return TradeDirection.buy;
      case CandlePattern.bearishPinbar:
      case CandlePattern.bearishEngulfing:
      case CandlePattern.bearishMomentum:
      case CandlePattern.bearishAbsorption:
        return TradeDirection.sell;
      case CandlePattern.doji:
      case CandlePattern.none:
        return null;
    }
  }

  double _round(double v) => double.parse(v.toStringAsFixed(2));
}
