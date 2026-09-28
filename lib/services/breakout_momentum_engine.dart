import 'dart:math';

import '../config/app_config.dart';
import '../models/candle.dart';
import '../models/pivot.dart';
import 'ta_engine.dart';

enum BreakoutLevelKind {
  sessionHigh,
  sessionLow,
  openingRangeHigh,
  openingRangeLow,
  previousDayHigh,
  previousDayLow,
  htfResistance,
  htfSupport,
  swingHigh,
  swingLow,
}

extension BreakoutLevelDirection on BreakoutLevelKind {
  /// Every level here only ever produces a trigger in ONE direction — a
  /// break UP through a High/Resistance, or DOWN through a Low/Support.
  /// Breaking a High from above (or a Low from below) isn't a breakout of
  /// THAT level at all, just price sitting on its already-established
  /// side, so [BreakoutMomentumEngine.findTrigger] never even tests the
  /// other direction against a given level.
  TradeDirection get breakoutDirection => switch (this) {
        BreakoutLevelKind.sessionHigh ||
        BreakoutLevelKind.openingRangeHigh ||
        BreakoutLevelKind.previousDayHigh ||
        BreakoutLevelKind.htfResistance ||
        BreakoutLevelKind.swingHigh =>
          TradeDirection.buy,
        BreakoutLevelKind.sessionLow ||
        BreakoutLevelKind.openingRangeLow ||
        BreakoutLevelKind.previousDayLow ||
        BreakoutLevelKind.htfSupport ||
        BreakoutLevelKind.swingLow =>
          TradeDirection.sell,
      };

  /// "مستوى مهم أولاً" (2026-09-22, explicit request): how structurally
  /// significant this kind of level is, 0-30. Drives BOTH the order levels
  /// are tested in (strongest first — the first qualifying one wins, so a
  /// multi-touch S/R beats a coarse session extreme sitting at the same
  /// price) AND its share of the Confluence Score.
  ///
  /// Ranked by how much prior price ACTION is behind the level: an HTF
  /// Support/Resistance only exists after [AppConfig.minSrTouches] separate
  /// rejections, a Previous Day High/Low is a full session's extreme every
  /// desk watches, a session extreme is a few hours', a swing point is one
  /// confirmed pivot, and an Opening Range is just the first 30-60 minutes
  /// of the day.
  int get importance => switch (this) {
        BreakoutLevelKind.htfResistance || BreakoutLevelKind.htfSupport => 30,
        BreakoutLevelKind.previousDayHigh || BreakoutLevelKind.previousDayLow => 25,
        BreakoutLevelKind.sessionHigh || BreakoutLevelKind.sessionLow => 22,
        BreakoutLevelKind.swingHigh || BreakoutLevelKind.swingLow => 20,
        BreakoutLevelKind.openingRangeHigh || BreakoutLevelKind.openingRangeLow => 15,
      };
}

/// A single structural level [BreakoutMomentumEngine] tracks — always a
/// flat price plus which direction breaking it means, never a live-moving
/// reference the way a trendline is.
class BreakoutLevel {
  final BreakoutLevelKind kind;
  final double price;
  final String label;
  const BreakoutLevel({required this.kind, required this.price, required this.label});
}

/// Which of the three entry patterns produced a [BreakoutTrigger].
enum BreakoutEntryKind {
  /// The breakout candle itself (only when [AppConfig.breakoutRequireRetest]
  /// is off).
  immediate,

  /// Break -> Retest -> resumption; the default.
  retest,

  /// Failed-Breakout Reversal (2026-09-22): the break was rejected, price
  /// CLOSED back through the level, and a further candle confirmed it —
  /// so the trade is taken in the OPPOSITE direction to the original
  /// break. See [BreakoutMomentumEngine.findTrigger]'s own doc comment.
  failedReversal,
}

/// A confirmed setup — every gate in [BreakoutMomentumEngine.findTrigger]
/// already passed by the time this exists.
class BreakoutTrigger {
  final BreakoutLevel level;
  final BreakoutEntryKind entryKind;

  /// The candle the ENTRY is priced off: the breakout candle itself in
  /// immediate mode, the post-retest resumption candle in retest mode, or
  /// the confirmation candle in a Failed-Breakout Reversal. Always the most
  /// recently CLOSED candle, so a trigger is never stale.
  final Candle candle;

  /// The candle that originally broke the level (== [candle] in immediate
  /// mode). Kept so the log/score can describe the break itself.
  final Candle breakoutCandle;

  final double atr;

  /// How far [candle]'s close sits beyond the level, in ATR — the
  /// "don't chase" measure (see [AppConfig.breakoutMaxEntryDistanceAtr]).
  /// Always measured from the level, whichever side the entry is on.
  final double entryDistanceAtr;

  /// The breakout candle's range as a multiple of the recent average range
  /// — the Momentum Confirmation measure (see
  /// [AppConfig.breakoutMinRangeToAvgRatio]).
  final double rangeExpansion;

  /// Failed-Breakout Reversal only: the furthest price the rejected break
  /// actually reached (the trap's own extreme). This is the reversal's
  /// natural invalidation — price getting back through it means the break
  /// wasn't a trap after all — so the Stop Loss is anchored here rather
  /// than to the level. Null for the two continuation kinds.
  final double? fakeoutExtreme;

  /// Failed-Breakout Reversal only: how far the entry sits from
  /// [fakeoutExtreme], in ATR — the reversal's own "don't chase" measure,
  /// and the one that actually determines its risk (see
  /// [AppConfig.breakoutReversalMaxTrapDistanceAtr]). Null for the two
  /// continuation kinds, whose risk is bounded by [entryDistanceAtr]
  /// instead.
  final double? trapDistanceAtr;

  const BreakoutTrigger({
    required this.level,
    required this.entryKind,
    required this.candle,
    required this.breakoutCandle,
    required this.atr,
    required this.entryDistanceAtr,
    required this.rangeExpansion,
    this.fakeoutExtreme,
    this.trapDistanceAtr,
  });

  bool get retestConfirmed => entryKind == BreakoutEntryKind.retest;
  bool get isFailedReversal => entryKind == BreakoutEntryKind.failedReversal;

  /// A Failed-Breakout Reversal trades AGAINST the level's own breakout
  /// direction — that is the entire point of it.
  TradeDirection get direction => isFailedReversal
      ? (level.kind.breakoutDirection == TradeDirection.buy ? TradeDirection.sell : TradeDirection.buy)
      : level.kind.breakoutDirection;
}

/// Standalone Breakout/Momentum strategy (2026-09-18, rebuilt 2026-09-22 to
/// an explicit 11-point specification) — isolated the same way OrbEngine is.
///
/// The decision chain, in order (the spec's own "نسخة احترافية" ordering;
/// the session/HTF/DXY/news gates live in SignalChecker.
/// _evaluateBreakoutTrigger because they need data this engine is
/// deliberately not given):
///
///   1. Important Level  — the level pool, strongest kind first
///                         ([BreakoutLevelDirection.importance]): multi-touch
///                         HTF S/R, Previous Day H/L, Asian/London/NY session
///                         H/L, confirmed Swing H/L, Opening Range H/L.
///   2. Breakout Candle  — an M5 CLOSE beyond the level with the WHOLE
///                         candle clear of it, a body inside the ATR band,
///                         and its close deep on the breakout side.
///   3. Momentum         — the breakout candle's range must EXPAND against
///                         the recent average ([rangeExpansion]).
///   4. Failed-Breakout  — any later M5 candle closing back through the
///      Protection        level kills that breakout permanently.
///   5. Retest           — (default) price must return to the level and HOLD
///                         it, then close beyond it again; that resumption
///                         candle is the entry.
///   6. Don't Chase      — the entry close must still be within
///                         [AppConfig.breakoutMaxEntryDistanceAtr] ATR of
///                         the level.
///
/// Everything above is stateless: the whole sequence is re-derived from the
/// candle array every cycle (same approach as OrbEngine), so there is no
/// cross-cycle state to get out of sync with the market.
class BreakoutMomentumEngine {
  final TaEngine _ta;
  BreakoutMomentumEngine([TaEngine? ta]) : _ta = ta ?? TaEngine();

  /// The three sessions this codebase already defines a UTC window for —
  /// reused as-is (see AppConfig's own session-hour constants) so "the
  /// London session" means the exact same hour everywhere. The Asian
  /// window is what the spec's "Asian Session High/Low" refers to.
  static const _sessions = [
    (label: 'Asian', start: AppConfig.asianSessionStartUtc, end: AppConfig.asianSessionEndUtc),
    (label: 'London', start: AppConfig.londonSessionStartUtc, end: AppConfig.londonSessionEndUtc),
    (label: 'New York', start: AppConfig.newYorkSessionStartUtc, end: AppConfig.newYorkSessionEndUtc),
  ];

  /// The most recently COMPLETED occurrence of a same-day, non-wrapping
  /// [startHour, endHour) UTC window as of [nowUtc] — today's if it has
  /// already ended, otherwise yesterday's (which has always already
  /// ended). Every session AppConfig defines is same-day and
  /// non-wrapping, so this never needs to handle a window crossing
  /// midnight.
  ({DateTime start, DateTime end}) _mostRecentCompletedWindow(int startHour, int endHour, DateTime nowUtc) {
    final todayStart = DateTime.utc(nowUtc.year, nowUtc.month, nowUtc.day, startHour);
    final todayEnd = DateTime.utc(nowUtc.year, nowUtc.month, nowUtc.day, endHour);
    if (!nowUtc.isBefore(todayEnd)) return (start: todayStart, end: todayEnd);
    return (start: todayStart.subtract(const Duration(days: 1)), end: todayEnd.subtract(const Duration(days: 1)));
  }

  /// Previous (most recently completed) session High/Low for every
  /// session AppConfig defines — built from [candles15m] (a multi-hour
  /// session window doesn't need 5M precision, and 15M is already fetched
  /// for every other tier regardless). A session with no candles inside
  /// its window yet (a gap, or not enough history fetched) contributes
  /// nothing for that session rather than failing the whole call.
  List<BreakoutLevel> previousSessionLevels(List<Candle> candles15m, DateTime nowUtc) {
    final levels = <BreakoutLevel>[];
    for (final session in _sessions) {
      final window = _mostRecentCompletedWindow(session.start, session.end, nowUtc);
      final inWindow =
          candles15m.where((c) => !c.time.isBefore(window.start) && c.time.isBefore(window.end)).toList();
      if (inWindow.isEmpty) continue;
      levels.add(BreakoutLevel(
        kind: BreakoutLevelKind.sessionHigh,
        price: inWindow.map((c) => c.high).reduce(max),
        label: '${session.label} Session High',
      ));
      levels.add(BreakoutLevel(
        kind: BreakoutLevelKind.sessionLow,
        price: inWindow.map((c) => c.low).reduce(min),
        label: '${session.label} Session Low',
      ));
    }
    return levels;
  }

  /// The Opening Range level source — [AppConfig.breakoutOpeningRangeStart/
  /// EndUtcMinutes], a UTC time-of-day window independently configurable
  /// from OrbEngine's fixed "first 30 minutes of a session" one. Uses
  /// today's window once it has closed, otherwise yesterday's (still
  /// tradeable) completed one — the same "most recently completed"
  /// convention as [previousSessionLevels]. Returns nothing when
  /// misconfigured (end <= start) or when no candles cover the window.
  List<BreakoutLevel> openingRangeLevels(List<Candle> candles15m, DateTime nowUtc) {
    final startMin = AppConfig.breakoutOpeningRangeStartUtcMinutes;
    final endMin = AppConfig.breakoutOpeningRangeEndUtcMinutes;
    if (endMin <= startMin) return const [];

    final today = DateTime.utc(nowUtc.year, nowUtc.month, nowUtc.day);
    final todayStart = today.add(Duration(minutes: startMin));
    final todayEnd = today.add(Duration(minutes: endMin));
    final window = !nowUtc.isBefore(todayEnd)
        ? (start: todayStart, end: todayEnd)
        : (start: todayStart.subtract(const Duration(days: 1)), end: todayEnd.subtract(const Duration(days: 1)));

    final inWindow = candles15m.where((c) => !c.time.isBefore(window.start) && c.time.isBefore(window.end)).toList();
    if (inWindow.isEmpty) return const [];

    return [
      BreakoutLevel(
        kind: BreakoutLevelKind.openingRangeHigh,
        price: inWindow.map((c) => c.high).reduce(max),
        label: 'Opening Range High',
      ),
      BreakoutLevel(
        kind: BreakoutLevelKind.openingRangeLow,
        price: inWindow.map((c) => c.low).reduce(min),
        label: 'Opening Range Low',
      ),
    ];
  }

  /// Previous Day High/Low — the most recently COMPLETED UTC calendar
  /// day's high/low. Takes [candlesH1] (already fetched for every other
  /// tier — no extra network request needed for a level this coarse).
  List<BreakoutLevel> previousDayLevels(List<Candle> candlesH1, DateTime nowUtc) {
    final today = DateTime.utc(nowUtc.year, nowUtc.month, nowUtc.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final inWindow = candlesH1.where((c) => !c.time.isBefore(yesterday) && c.time.isBefore(today)).toList();
    if (inWindow.isEmpty) return const [];

    return [
      BreakoutLevel(
        kind: BreakoutLevelKind.previousDayHigh,
        price: inWindow.map((c) => c.high).reduce(max),
        label: 'PDH (Previous Day High)',
      ),
      BreakoutLevel(
        kind: BreakoutLevelKind.previousDayLow,
        price: inWindow.map((c) => c.low).reduce(min),
        label: 'PDL (Previous Day Low)',
      ),
    ];
  }

  /// HTF Support/Resistance levels straight from TaEngine.buildHtfZones —
  /// Trendline-sourced zones are excluded (the spec asks for a flat
  /// "Support/Resistance تم اختباره عدة مرات", not a moving trendline).
  /// Every zone here already required at least [AppConfig.minSrTouches]
  /// separate touches to exist at all, which IS the spec's "tested
  /// several times" condition.
  List<BreakoutLevel> htfLevels(List<HtfZone> htfZones) {
    final levels = <BreakoutLevel>[];
    for (final zone in htfZones) {
      if (zone.source.contains('Resistance')) {
        levels.add(BreakoutLevel(kind: BreakoutLevelKind.htfResistance, price: zone.price, label: zone.source));
      } else if (zone.source.contains('Support')) {
        levels.add(BreakoutLevel(kind: BreakoutLevelKind.htfSupport, price: zone.price, label: zone.source));
      }
    }
    return levels;
  }

  /// Clear Swing High/Low levels (2026-09-22, spec point 1) — confirmed
  /// pivots on [candles15m] (a pivot is only confirmed once
  /// [AppConfig.breakoutSwingPivotLookback] candles have closed on BOTH
  /// sides of it, so this can never invent a level out of the still-moving
  /// right edge). Only the most recent [AppConfig.breakoutSwingMaxCount]
  /// of each side are kept — an hours-old swing is still structure, a
  /// week-old one is just noise in the pool.
  List<BreakoutLevel> swingLevels(List<Candle> candles15m) {
    if (candles15m.isEmpty) return const [];
    final pivots = _ta.findPivots(candles15m, lookback: AppConfig.breakoutSwingPivotLookback);
    if (pivots.isEmpty) return const [];

    List<BreakoutLevel> take(PivotType type, BreakoutLevelKind kind, String label) {
      final matching = pivots.where((p) => p.type == type).toList();
      final recent = matching.length > AppConfig.breakoutSwingMaxCount
          ? matching.sublist(matching.length - AppConfig.breakoutSwingMaxCount)
          : matching;
      return [
        for (final p in recent) BreakoutLevel(kind: kind, price: p.price, label: label),
      ];
    }

    return [
      ...take(PivotType.high, BreakoutLevelKind.swingHigh, '15M Swing High'),
      ...take(PivotType.low, BreakoutLevelKind.swingLow, '15M Swing Low'),
    ];
  }

  /// Orders the pool strongest-first and drops near-duplicates — two
  /// sources landing on effectively the SAME price (a Previous Day High
  /// that is also the London Session High, say) would otherwise be two
  /// chances at the same trade, and the weaker label could win the race
  /// purely by list order. The stronger [BreakoutLevelDirection.importance]
  /// survives; ties keep the first seen.
  List<BreakoutLevel> prioritize(List<BreakoutLevel> levels) {
    final sorted = [...levels]..sort((a, b) => b.kind.importance.compareTo(a.kind.importance));
    final kept = <BreakoutLevel>[];
    for (final level in sorted) {
      final duplicate = kept.any((k) =>
          k.kind.breakoutDirection == level.kind.breakoutDirection &&
          (k.price - level.price).abs() <= AppConfig.breakoutLevelDedupeDollars);
      if (!duplicate) kept.add(level);
    }
    return kept;
  }

  /// Average high-low range of the [period] candles ENDING at [endIndex]
  /// (exclusive) — the baseline the Momentum Confirmation measures a
  /// breakout candle's own range against. Deliberately excludes the candle
  /// being tested, so a single huge bar can't inflate the very average it
  /// then has to beat.
  double? averageRange(List<Candle> candles, int endIndex, {int period = 14}) {
    final start = endIndex - period;
    if (start < 0 || endIndex > candles.length) return null;
    var sum = 0.0;
    for (var i = start; i < endIndex; i++) {
      sum += candles[i].range;
    }
    final avg = sum / period;
    return avg > 0 ? avg : null;
  }

  /// Spec point 2 + 3 + the Whole-Candle Break rule (2026-09-21): is
  /// [candle] a genuine, strong break of [level]?
  ///
  ///  * Whole-Candle Break — the entire candle, wick included, sits beyond
  ///    the level ("شمعة كاملة عملت الكسر ومو بس جسم شمعة"), so a candle
  ///    still straddling the line never counts.
  ///  * Body vs ATR — inside
  ///    [[AppConfig.breakoutMinBodyToAtrRatio], [AppConfig.breakoutMaxBodyToAtrRatio]]:
  ///    too small is no real conviction, too large is a climax bar prone to
  ///    snapping straight back.
  ///  * Close Location — the close must sit in the top (BUY) / bottom
  ///    (SELL) [AppConfig.breakoutCloseLocationThreshold] of the candle's
  ///    own range, which is also what rules out a big opposing wick.
  ///  * Momentum/Range Expansion — the candle's range must beat
  ///    [AppConfig.breakoutMinRangeToAvgRatio] x the recent average range.
  bool isStrongBreakoutCandle(Candle candle, BreakoutLevel level, double atr, double avgRange) {
    if (candle.range <= 0 || atr <= 0 || avgRange <= 0) return false;
    final bullish = level.kind.breakoutDirection == TradeDirection.buy;

    final wholeCandleBeyond = bullish ? candle.low > level.price : candle.high < level.price;
    if (!wholeCandleBeyond) return false;

    final bodyToAtr = candle.bodySize / atr;
    if (bodyToAtr < AppConfig.breakoutMinBodyToAtrRatio || bodyToAtr > AppConfig.breakoutMaxBodyToAtrRatio) {
      return false;
    }

    if (!_closesOnBreakoutSide(candle, bullish)) return false;

    return candle.range / avgRange >= AppConfig.breakoutMinRangeToAvgRatio;
  }

  /// Close-Location filter alone (no body/range gates) — the breakout
  /// candle must clear the full [isStrongBreakoutCandle] bar, but a
  /// post-retest RESUMPTION candle only has to show directional conviction:
  /// price returning to a level and pushing off it again rarely produces
  /// another expansion bar, and demanding one there would reject almost
  /// every textbook retest entry.
  bool _closesOnBreakoutSide(Candle candle, bool bullish) {
    if (candle.range <= 0) return false;
    final closeLocation = (candle.close - candle.low) / candle.range; // 0 = at the low, 1 = at the high
    return bullish
        ? closeLocation >= AppConfig.breakoutCloseLocationThreshold
        : closeLocation <= (1 - AppConfig.breakoutCloseLocationThreshold);
  }

  bool _closedBeyond(Candle candle, BreakoutLevel level, bool bullish) =>
      bullish ? candle.close > level.price : candle.close < level.price;

  /// Spec point 4 — "لا تدخل بعد حركة مبالغ فيها": how far the entry sits
  /// beyond the level, measured in ATR. Anything past
  /// [AppConfig.breakoutMaxEntryDistanceAtr] is chasing a move that already
  /// happened.
  double _entryDistanceAtr(Candle entry, BreakoutLevel level, double atr) =>
      (entry.close - level.price).abs() / atr;

  /// Evaluates every entry of [levels] (strongest first — see [prioritize])
  /// against [candles5m], returning the first that clears the whole chain.
  ///
  /// [requireRetest] (spec point 5) switches between:
  ///   * false — the LAST candle must itself be the strong breakout candle;
  ///   * true  — a strong breakout candle must have formed within the last
  ///             [AppConfig.breakoutRetestLookbackCandles], price must then
  ///             have come back and HELD the level, and the LAST candle
  ///             must close beyond it again (that resumption is the entry).
  ///
  /// Either way the entry is always the most recently CLOSED candle, so a
  /// trigger can never be a stale replay of something hours old, and
  /// Failed-Breakout Protection (spec point 11) invalidates any breakout a
  /// later candle closed back through.
  ///
  /// Returns null when ATR/range baselines can't be computed yet (not
  /// enough candles), or when nothing in [levels] qualifies.
  BreakoutTrigger? findTrigger(
    List<Candle> candles5m,
    List<BreakoutLevel> levels, {
    required bool requireRetest,
  }) {
    if (levels.isEmpty) return null;
    final lastIndex = candles5m.length - 1;
    if (lastIndex < 1) return null;

    final atr = _ta.averageTrueRange(candles5m, period: 14);
    if (atr == null || atr <= 0) return null;
    if (candles5m.last.range <= 0) return null;

    for (final level in levels) {
      final trigger = requireRetest
          ? _retestTrigger(candles5m, level, atr, lastIndex)
          : _immediateTrigger(candles5m, level, atr, lastIndex);
      if (trigger != null) return trigger;

      if (AppConfig.breakoutFailedReversalEnabled) {
        final reversal = _failedReversalTrigger(candles5m, level, atr, lastIndex);
        if (reversal != null) return reversal;
      }
    }
    return null;
  }

  /// Failed-Breakout Reversal (2026-09-22, explicit request) — the trap
  /// trade: a strong break that gets REJECTED traps everyone who joined it,
  /// and their forced exits fuel the move the other way.
  ///
  /// Requires, in order:
  ///   1. a genuine strong breakout candle `b` (the exact same bar as a
  ///      normal entry would need — a weak poke failing proves nothing);
  ///   2. a FAILURE candle `f`, within
  ///      [AppConfig.breakoutFailedReversalMaxCandles] of `b`, that CLOSES
  ///      back through the level (a wick back is not a failure);
  ///   3. a CONFIRMATION candle — the last closed candle, after `f`
  ///      ("ما ياخدو الا ليكون في شمعة تاكيدية بتاكد فشل الاختراق") — that
  ///      is still on the failure side of the level, closes BEYOND `f`'s
  ///      own close (the rejection is extending, not stalling), and closes
  ///      decisively on that side of its own range.
  ///
  /// The Stop Loss anchor ([BreakoutTrigger.fakeoutExtreme]) is the
  /// furthest the trap itself ran. Note SignalChecker's blanket minimum-SL
  /// filter still applies afterwards, which is what rules out the
  /// degenerate case of a break that barely moved before failing (its stop
  /// would be a couple of pips wide and pure noise).
  BreakoutTrigger? _failedReversalTrigger(List<Candle> candles, BreakoutLevel level, double atr, int lastIndex) {
    final bullishBreak = level.kind.breakoutDirection == TradeDirection.buy;
    final confirmation = candles[lastIndex];

    // 3a. The confirmation candle must sit on the FAILURE side of the level.
    final confirmationRejects = bullishBreak ? confirmation.close < level.price : confirmation.close > level.price;
    if (!confirmationRejects) return null;
    // ...and close decisively in the reversal direction within its own range.
    if (!_closesOnBreakoutSide(confirmation, !bullishBreak)) return null;

    final maxAge = AppConfig.breakoutFailedReversalMaxCandles;
    final windowStart = max(1, lastIndex - maxAge);

    for (var b = lastIndex - 2; b >= windowStart; b--) {
      final avgRange = averageRange(candles, b);
      if (avgRange == null) continue;
      if (!isStrongBreakoutCandle(candles[b], level, atr, avgRange)) continue;

      // 2. The first candle after b that CLOSES back through the level.
      var failureIndex = -1;
      for (var i = b + 1; i < lastIndex; i++) {
        if (_closedBeyond(candles[i], level, !bullishBreak)) {
          failureIndex = i;
          break;
        }
      }
      if (failureIndex < 0) continue;

      // 3b. The confirmation must EXTEND the rejection past the failure
      // candle's own close, not merely hover next to it.
      final failure = candles[failureIndex];
      final extending =
          bullishBreak ? confirmation.close < failure.close : confirmation.close > failure.close;
      if (!extending) continue;

      // The trap's own extreme, from the break through to the failure —
      // the reversal's invalidation level.
      var extreme = bullishBreak ? candles[b].high : candles[b].low;
      for (var i = b + 1; i <= failureIndex; i++) {
        extreme = bullishBreak ? max(extreme, candles[i].high) : min(extreme, candles[i].low);
      }

      // The reversal's own "don't chase" limit: the entry must still be
      // near the extreme its Stop Loss hangs off, or the trade is priced at
      // a risk the setup never justified (see
      // AppConfig.breakoutReversalMaxTrapDistanceAtr for the live case that
      // motivated this).
      final trapDistanceAtr = (confirmation.close - extreme).abs() / atr;
      if (trapDistanceAtr > AppConfig.breakoutReversalMaxTrapDistanceAtr) continue;

      return BreakoutTrigger(
        level: level,
        entryKind: BreakoutEntryKind.failedReversal,
        candle: confirmation,
        breakoutCandle: candles[b],
        atr: atr,
        entryDistanceAtr: (confirmation.close - level.price).abs() / atr,
        rangeExpansion: candles[b].range / avgRange,
        fakeoutExtreme: extreme,
        trapDistanceAtr: trapDistanceAtr,
      );
    }
    return null;
  }

  BreakoutTrigger? _immediateTrigger(List<Candle> candles, BreakoutLevel level, double atr, int lastIndex) {
    final avgRange = averageRange(candles, lastIndex);
    if (avgRange == null) return null;

    final entry = candles[lastIndex];
    if (!isStrongBreakoutCandle(entry, level, atr, avgRange)) return null;

    final distance = _entryDistanceAtr(entry, level, atr);
    if (distance > AppConfig.breakoutMaxEntryDistanceAtr) return null;

    return BreakoutTrigger(
      level: level,
      candle: entry,
      breakoutCandle: entry,
      atr: atr,
      entryKind: BreakoutEntryKind.immediate,
      entryDistanceAtr: distance,
      rangeExpansion: entry.range / avgRange,
    );
  }

  BreakoutTrigger? _retestTrigger(List<Candle> candles, BreakoutLevel level, double atr, int lastIndex) {
    final bullish = level.kind.breakoutDirection == TradeDirection.buy;
    final entry = candles[lastIndex];

    // The entry candle must itself resume the break: closed beyond the
    // level, pushing off it (close-location), and still not chasing.
    if (!_closedBeyond(entry, level, bullish)) return null;
    if (!_closesOnBreakoutSide(entry, bullish)) return null;
    final distance = _entryDistanceAtr(entry, level, atr);
    if (distance > AppConfig.breakoutMaxEntryDistanceAtr) return null;

    // Walk back for the strong breakout candle that started this move —
    // most recent first, so the freshest structure wins.
    final windowStart = max(1, lastIndex - AppConfig.breakoutRetestLookbackCandles);
    for (var b = lastIndex - 1; b >= windowStart; b--) {
      final avgRange = averageRange(candles, b);
      if (avgRange == null) continue;
      if (!isStrongBreakoutCandle(candles[b], level, atr, avgRange)) continue;

      // Failed-Breakout Protection (spec point 11): a CLOSE back through
      // the level at any point after the break kills it outright — the
      // move is a fakeout, not a pullback, and no later retest can
      // rehabilitate it.
      var failed = false;
      var retested = false;
      for (var i = b + 1; i <= lastIndex; i++) {
        if (_closedBeyond(candles[i], level, !bullish)) {
          failed = true;
          break;
        }
        // The retest itself: price traded back INTO the level (wick is
        // enough — holding it is what matters, and the close-back case is
        // already caught as a failure above) on some candle before the
        // entry one.
        if (i < lastIndex) {
          final touched = bullish
              ? candles[i].low <= level.price + AppConfig.breakoutRetestToleranceDollars
              : candles[i].high >= level.price - AppConfig.breakoutRetestToleranceDollars;
          if (touched) retested = true;
        }
      }
      if (failed || !retested) continue;

      return BreakoutTrigger(
        level: level,
        candle: entry,
        breakoutCandle: candles[b],
        atr: atr,
        entryKind: BreakoutEntryKind.retest,
        entryDistanceAtr: distance,
        rangeExpansion: candles[b].range / avgRange,
      );
    }
    return null;
  }
}
