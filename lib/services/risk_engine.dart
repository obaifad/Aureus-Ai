import '../config/app_config.dart';
import '../models/candle.dart';
import '../models/pivot.dart';
import '../models/trade_setup.dart';

/// Turns a confirmed setup zone + candlestick pattern into a fully
/// priced TradeSetup with a strict 1:2 Risk:Reward ratio.
class RiskEngine {
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
    final prevCandle = isAbsorption ? candles[zone.candleIndex - 1] : null;

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
    double stopLoss;
    if (direction == TradeDirection.buy) {
      if (isAbsorption) {
        stopLoss = prevCandle!.low - AppConfig.slBufferDollars;
      } else {
        final outerWick = confirmationCandle.low;
        final belowZone = zone.zonePrice - AppConfig.slBufferDollars;
        stopLoss = [outerWick, belowZone].reduce((a, b) => a < b ? a : b) -
            AppConfig.slBufferDollars;
      }
    } else {
      if (isAbsorption) {
        stopLoss = prevCandle!.high + AppConfig.slBufferDollars;
      } else {
        final outerWick = confirmationCandle.high;
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
      detectedAt: DateTime.now().toUtc(),
      slWasClamped: slWasClamped,
    );
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
