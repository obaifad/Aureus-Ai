import 'dart:math';

import '../config/app_config.dart';
import '../models/candle.dart';
import '../models/pivot.dart' show TradeDirection;

/// Market-dynamics safety layers (2026-10-07) — the pure logic of the Fast-Impulse Guard and the
/// Volatility / Chaos Filter. (The third layer, the ICT Liquidity-Sweep realignment, is part of
/// IctEngine because it reads that engine's own structure helpers.)
///
/// Everything here is a pure function of the candles and the time it is handed: no clock, no network, no
/// state. SignalChecker feeds it the closed candles of the scan, so a restart forgets nothing (the
/// verdict is re-derived from the history) and a backtest replays it exactly as live. WHETHER a verdict
/// blocks anything is decided by the caller from the layer's GuardMode (off | shadow | block).

/// The tag at the start of every [TradeSetup.shadowFlags] entry, naming the layer that would have
/// rejected the setup had it been enforcing.
class ShadowLayer {
  ShadowLayer._();
  static const impulse = 'impulse_guard';
  static const chaos = 'chaos_filter';
  static const ictSweep = 'ict_sweep_alignment';
}

/// `HH:mm` of [t] in UTC — how every guard message states a time.
String formatUtcHm(DateTime t) {
  final u = t.toUtc();
  return '${u.hour.toString().padLeft(2, '0')}:${u.minute.toString().padLeft(2, '0')}';
}

double _median(List<double> values) {
  final sorted = [...values]..sort();
  final mid = sorted.length ~/ 2;
  return sorted.length.isOdd ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

/// Wilder's ATR(period) as of EVERY candle: element `i` covers `candles[0..i]` and is null until
/// `period + 1` candles exist. The last element equals TaEngine.averageTrueRange(candles); this keeps
/// the whole series so a detector can read "the ATR just before candle i" without recomputing.
List<double?> atrSeries(List<Candle> candles, {int period = 14}) {
  final out = List<double?>.filled(candles.length, null);
  if (candles.length < period + 1) return out;
  final tr = List<double>.filled(candles.length, 0);
  for (var i = 1; i < candles.length; i++) {
    final c = candles[i];
    final prevClose = candles[i - 1].close;
    tr[i] = max(c.high - c.low, max((c.high - prevClose).abs(), (c.low - prevClose).abs()));
  }
  var atr = 0.0;
  for (var i = 1; i <= period; i++) {
    atr += tr[i];
  }
  atr /= period;
  out[period] = atr;
  for (var i = period + 1; i < candles.length; i++) {
    atr = (atr * (period - 1) + tr[i]) / period;
    out[i] = atr;
  }
  return out;
}

/// How HOT the 15M market is right now: ATR(14) as of the last candle divided by the median ATR(14) over the
/// last [normCandles] candles (288 = three days of 15M). 1.0 is a normal market, 1.2 is 20% hotter than its own
/// recent norm. Null when there is too little history for a meaningful norm (under ~25 hours of ATR values) —
/// the caller must treat that as "no opinion", never as hot.
double? atrHeat(List<Candle> closed15m, {int normCandles = 288}) {
  final series = atrSeries(closed15m);
  final now = series.isEmpty ? null : series.last;
  if (now == null) return null;
  final recent = series.length > normCandles ? series.sublist(series.length - normCandles) : series;
  final values = [
    for (final v in recent)
      if (v != null) v,
  ];
  if (values.length < 100) return null;
  final norm = _median(values);
  return norm <= 0 ? null : now / norm;
}

/// How far price ran over the last [candles] closed 15M candles (8 = two hours), close to close, measured in
/// ATR(14) as of the last candle. SIGNED: positive = price rose, negative = it fell. Null when there are too few
/// candles or no usable ATR — the caller must treat that as "no opinion", never as a sharp move.
double? recentMoveAtr(List<Candle> closed15m, {int candles = 8}) {
  if (closed15m.length < candles + 1) return null;
  final atr = atrSeries(closed15m).last;
  if (atr == null || atr <= 0) return null;
  return (closed15m.last.close - closed15m[closed15m.length - 1 - candles].close) / atr;
}

// ---------------------------------------------------------------------------
// Fast-Impulse Guard
// ---------------------------------------------------------------------------

class ImpulseParams {
  /// Consecutive same-direction high-momentum candles that make an impulse.
  final int consecutive;

  /// "High momentum": body / range at least this, and body at least [minBodyAtr] x ATR(14).
  final double minBodyRatio;
  final double minBodyAtr;

  /// A single candle whose range exceeds this many ATR(14) is a shock candle on its own.
  final double shockAtr;

  /// How long a momentum run / a shock candle restricts counter-trend mean-reversion entries.
  final double minHours;
  final double maxHours;

  const ImpulseParams({
    this.consecutive = AppConfig.impulseConsecutiveDefault,
    this.minBodyRatio = AppConfig.impulseMinBodyRatioDefault,
    this.minBodyAtr = AppConfig.impulseMinBodyAtrDefault,
    this.shockAtr = AppConfig.impulseShockAtrDefault,
    this.minHours = AppConfig.impulseMinHoursDefault,
    this.maxHours = AppConfig.impulseMaxHoursDefault,
  });

  /// What the bridge config (or, without one, the built-in defaults) says right now.
  factory ImpulseParams.current() => ImpulseParams(
        consecutive: AppConfig.impulseConsecutive,
        minBodyRatio: AppConfig.impulseMinBodyRatio,
        minBodyAtr: AppConfig.impulseMinBodyAtr,
        shockAtr: AppConfig.impulseShockAtr,
        minHours: AppConfig.impulseMinHours,
        maxHours: AppConfig.impulseMaxHours,
      );
}

enum ImpulseKind { momentumRun, shockCandle }

/// One detected impulse: which way it went, how big, and until when it restricts counter-trend entries.
class ImpulseEvent {
  final TradeDirection direction;
  final ImpulseKind kind;

  /// 'M15' or 'M5'.
  final String timeframe;

  /// UTC close time of the candle that completed it.
  final DateTime endsAt;
  final DateTime restrictUntil;

  /// Shock candle: its range / ATR. Momentum run: the summed bodies / ATR (the net move in ATRs).
  final double magnitudeAtr;

  const ImpulseEvent({
    required this.direction,
    required this.kind,
    required this.timeframe,
    required this.endsAt,
    required this.restrictUntil,
    required this.magnitudeAtr,
  });

  bool activeAt(DateTime nowUtc) => !nowUtc.isBefore(endsAt) && nowUtc.isBefore(restrictUntil);

  String get label => '${direction == TradeDirection.buy ? 'bullish' : 'bearish'} '
      '${kind == ImpulseKind.shockCandle ? 'shock candle' : 'momentum run'} '
      '(${magnitudeAtr.toStringAsFixed(1)}×ATR, $timeframe, closed ${formatUtcHm(endsAt)} UTC)';
}

/// What the impulse detector says about "now": the impulses still restricting entries, newest first.
class ImpulseVerdict {
  final List<ImpulseEvent> active;
  const ImpulseVerdict(this.active);

  static const ImpulseVerdict none = ImpulseVerdict([]);

  bool get isActive => active.isNotEmpty;

  /// The active impulse that forbids a [direction] entry, or null. A mean-reversion trade AGAINST an
  /// impulse is the counter-trend one: after a bearish impulse a BUY is restricted, a SELL is not. Two
  /// opposite impulses inside the windows restrict both ways — a market that whipsaws that hard is not
  /// one to fade.
  ImpulseEvent? blockerFor(TradeDirection direction) {
    for (final event in active) {
      if (event.direction != direction) return event;
    }
    return null;
  }
}

class ImpulseDetector {
  const ImpulseDetector();

  /// A shock candle needs at least this body / range to have a direction at all: a huge range that
  /// closed back where it opened is a spike (the chaos filter's business), not a push one way.
  static const double shockMinBodyRatio = 0.30;

  /// Every impulse in [closed] (CLOSED candles only, oldest first) that could still be restricting
  /// entries at [nowUtc]. Candle `i` is judged against the ATR(14) of the candles BEFORE it, so a shock
  /// candle cannot inflate its own yardstick.
  List<ImpulseEvent> events(
    List<Candle> closed, {
    required int timeframeMinutes,
    required String label,
    required DateTime nowUtc,
    required ImpulseParams params,
  }) {
    if (closed.length < 16) return const [];
    final atr = atrSeries(closed);
    final horizon = nowUtc.subtract(_hours(max(params.minHours, params.maxHours)));
    final out = <ImpulseEvent>[];
    for (var i = closed.length - 1; i >= 1; i--) {
      final c = closed[i];
      final endsAt = c.time.toUtc().add(Duration(minutes: timeframeMinutes));
      if (!endsAt.isAfter(horizon)) break; // too old to restrict anything now
      final before = atr[i - 1];
      if (before == null || before <= 0) continue;

      if (c.range > params.shockAtr * before && c.bodySize >= c.range * shockMinBodyRatio) {
        out.add(ImpulseEvent(
          direction: c.close > c.open ? TradeDirection.buy : TradeDirection.sell,
          kind: ImpulseKind.shockCandle,
          timeframe: label,
          endsAt: endsAt,
          restrictUntil: endsAt.add(_hours(params.maxHours)),
          magnitudeAtr: c.range / before,
        ));
        continue;
      }

      final run = _momentumRun(closed, atr, i, params);
      if (run != null) {
        out.add(ImpulseEvent(
          direction: run.direction,
          kind: ImpulseKind.momentumRun,
          timeframe: label,
          endsAt: endsAt,
          restrictUntil: endsAt.add(_hours(params.minHours)),
          magnitudeAtr: run.magnitudeAtr,
        ));
      }
    }
    return out;
  }

  ({TradeDirection direction, double magnitudeAtr})? _momentumRun(
    List<Candle> closed,
    List<double?> atr,
    int last,
    ImpulseParams params,
  ) {
    final first = last - params.consecutive + 1;
    if (first < 1) return null;
    TradeDirection? direction;
    var magnitude = 0.0;
    for (var j = first; j <= last; j++) {
      final before = atr[j - 1];
      final c = closed[j];
      if (before == null || before <= 0 || c.range <= 0) return null;
      final body = c.bodySize;
      if (body < c.range * params.minBodyRatio || body < params.minBodyAtr * before) return null;
      final dir = c.close > c.open ? TradeDirection.buy : TradeDirection.sell;
      if (direction != null && direction != dir) return null;
      direction = dir;
      magnitude += body / before;
    }
    return (direction: direction!, magnitudeAtr: magnitude);
  }

  /// The impulses restricting entries at [nowUtc], from the closed 15M candles and — when the caller
  /// has them — the closed 5M candles too.
  ImpulseVerdict assess({
    required List<Candle> m15,
    List<Candle> m5 = const [],
    required DateTime nowUtc,
    required ImpulseParams params,
  }) {
    final all = [
      ...events(m15, timeframeMinutes: 15, label: 'M15', nowUtc: nowUtc, params: params),
      if (m5.isNotEmpty) ...events(m5, timeframeMinutes: 5, label: 'M5', nowUtc: nowUtc, params: params),
    ];
    final active = all.where((e) => e.activeAt(nowUtc)).toList()..sort((a, b) => b.endsAt.compareTo(a.endsAt));
    return active.isEmpty ? ImpulseVerdict.none : ImpulseVerdict(active);
  }

  static Duration _hours(double hours) => Duration(minutes: (hours * 60).round());
}

// ---------------------------------------------------------------------------
// Volatility & Chaos Filter
// ---------------------------------------------------------------------------

class ChaosParams {
  /// A candle range / spread this many times the time-of-day median is stress.
  final double rangeMult;
  final double spreadMult;

  /// How many prior trading days make the baseline.
  final int baselineDays;

  /// How long after the last stressed candle closes the pause holds.
  final int pauseMinutes;

  /// Fewer same-slot samples than this and there is no baseline for that slot (the comparison is skipped).
  static const int minSamples = 8;

  /// A spread below this many pips is never "stress", however small the median it is compared with.
  static const double minStressSpreadPips = 2.0;

  const ChaosParams({
    this.rangeMult = AppConfig.chaosRangeMultDefault,
    this.spreadMult = AppConfig.chaosSpreadMultDefault,
    this.baselineDays = AppConfig.chaosBaselineDaysDefault,
    this.pauseMinutes = AppConfig.chaosPauseMinutesDefault,
  });

  factory ChaosParams.current() => ChaosParams(
        rangeMult: AppConfig.chaosRangeMult,
        spreadMult: AppConfig.chaosSpreadMult,
        baselineDays: AppConfig.chaosBaselineDays,
        pauseMinutes: AppConfig.chaosPauseMinutes,
      );
}

typedef _Sample = ({int day, DateTime time, double range, double? spread});

/// What a 15-minute slot of the UTC day normally looks like: the MEDIAN candle range (and bar spread)
/// of that same slot over the last [days] trading days. A quiet Asian-session quarter-hour and the New
/// York open are each judged against their own normal, which a plain ATR cannot do.
///
/// A candle is only ever compared with samples from strictly EARLIER days, so no baseline contains the
/// candle it judges and none looks ahead.
class VolatilityBaseline {
  static const int slotMinutes = 15;

  final DateTime builtAt;
  final int days;
  final Map<int, List<_Sample>> _bySlot;

  VolatilityBaseline._(this.builtAt, this.days, this._bySlot);

  /// Built from CLOSED 15M candles (oldest first). Flat candles (no range — a closed market) are
  /// left out: they would drag every median toward zero.
  factory VolatilityBaseline.build(
    List<Candle> closed15m, {
    required DateTime nowUtc,
    int days = AppConfig.chaosBaselineDaysDefault,
  }) {
    final bySlot = <int, List<_Sample>>{};
    for (final c in closed15m) {
      if (c.range <= 0) continue;
      bySlot.putIfAbsent(slotOf(c.time), () => []).add((day: dayKeyOf(c.time), time: c.time, range: c.range, spread: c.spreadPips));
    }
    for (final samples in bySlot.values) {
      samples.sort((a, b) => a.time.compareTo(b.time));
    }
    return VolatilityBaseline._(nowUtc, days, bySlot);
  }

  static int slotOf(DateTime t) {
    final u = t.toUtc();
    return (u.hour * 60 + u.minute) ~/ slotMinutes;
  }

  static int dayKeyOf(DateTime t) {
    final u = t.toUtc();
    return u.year * 10000 + u.month * 100 + u.day;
  }

  List<_Sample> _prior(DateTime candleTime) {
    final samples = _bySlot[slotOf(candleTime)];
    if (samples == null) return const [];
    final day = dayKeyOf(candleTime);
    final earlier = samples.where((s) => s.day < day).toList();
    return earlier.length <= days ? earlier : earlier.sublist(earlier.length - days);
  }

  /// How many earlier days have a sample for [candleTime]'s slot.
  int sampleCount(DateTime candleTime) => _prior(candleTime).length;

  /// The median candle range of [candleTime]'s slot, or null with fewer than [ChaosParams.minSamples] days.
  double? medianRange(DateTime candleTime) {
    final prior = _prior(candleTime);
    if (prior.length < ChaosParams.minSamples) return null;
    return _median([for (final s in prior) s.range]);
  }

  /// The median bar spread (pips) of [candleTime]'s slot, or null when the history carries no spread
  /// (only the MT5 bridge supplies it) or too little of it.
  double? medianSpread(DateTime candleTime) {
    final spreads = [
      for (final s in _prior(candleTime))
        if (s.spread != null && s.spread! > 0) s.spread!,
    ];
    if (spreads.length < ChaosParams.minSamples) return null;
    return _median(spreads);
  }
}

class ChaosVerdict {
  /// True when the market is in liquidity stress / extreme volatility right now.
  final bool stressed;

  /// False when there was nothing to compare against (no baseline, or too few samples) — "no opinion".
  final bool baselineReady;

  /// The largest candle-range / median ratio observed in the pause window, and the largest spread ratio.
  final double? rangeRatio;
  final double? spreadRatio;

  /// Open time of the candle behind a range stress; null for a pure spread stress. Lets a caller log a
  /// continuing stress once rather than on every scan.
  final DateTime? candleTime;
  final String reason;

  const ChaosVerdict({
    required this.stressed,
    required this.baselineReady,
    this.rangeRatio,
    this.spreadRatio,
    this.candleTime,
    this.reason = '',
  });

  static const ChaosVerdict unavailable = ChaosVerdict(stressed: false, baselineReady: false, reason: 'no volatility baseline');

  /// Identifies one stress episode for de-duplicated logging.
  String get episodeKey => '${candleTime?.toUtc().toIso8601String() ?? 'spread'}|${stressed ? 1 : 0}';
}

class ChaosDetector {
  const ChaosDetector();

  /// Judges the market at [nowUtc].
  ///
  /// The candles looked at are the closed 15M candles that finished within the last
  /// [ChaosParams.pauseMinutes] (so a stressed candle keeps the pause on until that long after it
  /// closes) plus the still-forming one — its range so far can only UNDER-state the final range, so
  /// including it is fast without being trigger-happy. [liveSpreadPips] is the spread right now; each
  /// candle's own [Candle.spreadPips] is judged too when the history carries one.
  ///
  /// With no [baseline] the verdict is "no opinion, not stressed": the filter never blocks on a failure.
  ChaosVerdict assess({
    required List<Candle> closed15m,
    Candle? forming,
    required VolatilityBaseline? baseline,
    required DateTime nowUtc,
    double? liveSpreadPips,
    required ChaosParams params,
  }) {
    if (baseline == null) return ChaosVerdict.unavailable;

    final cutoff = nowUtc.subtract(Duration(minutes: params.pauseMinutes));
    final observed = <Candle>[];
    for (var i = closed15m.length - 1; i >= 0; i--) {
      final closesAt = closed15m[i].time.toUtc().add(const Duration(minutes: VolatilityBaseline.slotMinutes));
      if (!closesAt.isAfter(cutoff)) break;
      observed.add(closed15m[i]);
    }
    if (forming != null) observed.add(forming);

    var ready = false;
    double? worstRange;
    DateTime? worstRangeAt;
    double? worstRangeMedian;
    double? worstRangeValue;
    double? worstSpread;
    String? spreadNote;
    var spreadStressed = false;

    void judgeSpread(double spread, double median, String source) {
      ready = true;
      final ratio = spread / median;
      if (worstSpread == null || ratio > worstSpread!) {
        worstSpread = ratio;
        spreadNote = '$source spread ${spread.toStringAsFixed(1)} pips = ${ratio.toStringAsFixed(1)}× the '
            '${median.toStringAsFixed(1)}-pip median';
      }
      if (spread >= ChaosParams.minStressSpreadPips && ratio >= params.spreadMult) spreadStressed = true;
    }

    for (final c in observed) {
      final median = baseline.medianRange(c.time);
      if (median != null && median > 0) {
        ready = true;
        final ratio = c.range / median;
        if (worstRange == null || ratio > worstRange) {
          worstRange = ratio;
          worstRangeAt = c.time;
          worstRangeMedian = median;
          worstRangeValue = c.range;
        }
      }
      final spread = c.spreadPips;
      final spreadMedian = baseline.medianSpread(c.time);
      if (spread != null && spreadMedian != null && spreadMedian > 0) judgeSpread(spread, spreadMedian, 'candle');
    }
    if (liveSpreadPips != null) {
      final spreadMedian = baseline.medianSpread(nowUtc);
      if (spreadMedian != null && spreadMedian > 0) judgeSpread(liveSpreadPips, spreadMedian, 'live');
    }

    final rangeStressed = worstRange != null && worstRange >= params.rangeMult;
    final reasons = [
      if (rangeStressed)
        'candle ${formatUtcHm(worstRangeAt!)} UTC range \$${worstRangeValue!.toStringAsFixed(2)} = ${worstRange.toStringAsFixed(1)}× '
            'the \$${worstRangeMedian!.toStringAsFixed(2)} ${params.baselineDays}-day median for that time of day',
      if (spreadStressed) spreadNote!,
    ];
    return ChaosVerdict(
      stressed: rangeStressed || spreadStressed,
      baselineReady: ready,
      rangeRatio: worstRange,
      spreadRatio: worstSpread,
      candleTime: rangeStressed ? worstRangeAt : null,
      reason: reasons.isEmpty ? (ready ? 'normal' : 'not enough history for this time of day') : reasons.join('; '),
    );
  }
}
