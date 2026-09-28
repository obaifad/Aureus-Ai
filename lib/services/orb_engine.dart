import 'dart:math';

import '../config/app_config.dart';
import '../models/candle.dart';
import '../models/pivot.dart';

enum OrbSession { london, newYork }

extension OrbSessionInfo on OrbSession {
  String get label => switch (this) {
        OrbSession.london => 'London',
        OrbSession.newYork => 'New York',
      };

  /// Reuses the exact same UTC session-start constants IctEngine's session
  /// filter and every other part of this codebase already read — "the
  /// London session" means the same hour everywhere, not a second,
  /// independently-tunable number here.
  int get startHourUtc => switch (this) {
        OrbSession.london => AppConfig.londonSessionStartUtc,
        OrbSession.newYork => AppConfig.newYorkSessionStartUtc,
      };

  bool get enabled => switch (this) {
        OrbSession.london => AppConfig.orbLondonEnabled,
        OrbSession.newYork => AppConfig.orbNewYorkEnabled,
      };
}

/// Today's Opening Range for one session — the high/low of the first
/// [AppConfig.orbRangeMinutes] after it opens (UTC), built strictly from
/// CLOSED 5M candles.
class OrbRange {
  final OrbSession session;
  final DateTime rangeStart;
  final DateTime rangeEnd;
  final double high;
  final double low;

  const OrbRange({
    required this.session,
    required this.rangeStart,
    required this.rangeEnd,
    required this.high,
    required this.low,
  });

  /// Stable per-session-per-day identity — the "Single Trade per Range"
  /// key SignalChecker's debounce state is keyed on (see
  /// SignalChecker._consumedOrbRanges), so London and New York never share
  /// one, and a new calendar day always starts a fresh key.
  String get key => '${session.name}#${rangeStart.year}-'
      '${rangeStart.month.toString().padLeft(2, '0')}-'
      '${rangeStart.day.toString().padLeft(2, '0')}';
}

/// A qualifying ORB entry — always mechanical, never dependent on any HTF
/// zone, structure bias, or candlestick pattern (see [OrbEngine]'s own doc
/// comment for why that isolation is deliberate).
class OrbTrigger {
  final OrbRange range;
  final TradeDirection direction;
  final Candle entryCandle;

  const OrbTrigger({
    required this.range,
    required this.direction,
    required this.entryCandle,
  });
}

/// Standalone Opening Range Breakout strategy (2026-09-18, explicit
/// request) — deliberately ISOLATED from TaEngine/IctEngine/
/// ImpulseCorrectionEngine: it never reads an HTF zone, a swing pivot, or a
/// structure bias, only the raw 5M candles of the session it's watching.
/// SignalChecker wires it in as a fourth, independent tier with its own
/// debounce state (see SignalChecker._evaluateOrbTrigger), exactly like
/// ICT/ICI, and applies the (separate, cross-cutting) DXY Correlation
/// Filter to its output the same as every other tier's.
class OrbEngine {
  /// Builds today's Opening Range for [session] from [candles5m] — every
  /// CLOSED 5M candle whose open time falls in [session's start, start +
  /// [AppConfig.orbRangeMinutes]). Returns null while that window hasn't
  /// fully closed yet ([nowUtc] hasn't reached its end) or when the feed is
  /// missing candles inside it (a gap/outage right at the session open) — a
  /// range built from a partial window would be meaningless as tradeable
  /// structure. The required candle count is DERIVED from the configured
  /// window length rather than hard-coded, so narrowing the window (30 ->
  /// 15 minutes, 2026-09-24) can't silently leave a stale "6 candles"
  /// completeness check that no 15-minute window could ever satisfy.
  OrbRange? computeRange(List<Candle> candles5m, OrbSession session, DateTime nowUtc) {
    final today = DateTime.utc(nowUtc.year, nowUtc.month, nowUtc.day, session.startHourUtc);
    final rangeEnd = today.add(const Duration(minutes: AppConfig.orbRangeMinutes));
    if (nowUtc.isBefore(rangeEnd)) return null;

    const minutesPerCandle = 5;
    const requiredCandles = AppConfig.orbRangeMinutes ~/ minutesPerCandle;
    final window = candles5m.where((c) => !c.time.isBefore(today) && c.time.isBefore(rangeEnd)).toList();
    if (window.length < requiredCandles) return null;

    return OrbRange(
      session: session,
      rangeStart: today,
      rangeEnd: rangeEnd,
      high: window.map((c) => c.high).reduce(max),
      low: window.map((c) => c.low).reduce(min),
    );
  }

  /// The instant [range] stops being tradeable — [AppConfig.
  /// orbMaxHoursAfterRange] past the close of its own opening window.
  /// Exposed on the engine (rather than buried inside [findTrigger]) so
  /// SignalChecker can say so in its scan notes.
  DateTime deadline(OrbRange range) =>
      range.rangeEnd.add(const Duration(hours: AppConfig.orbMaxHoursAfterRange));

  /// Scans the CLOSED 5M candles after [range] — up to its [deadline] —
  /// for a qualifying breakout.
  /// Stateless and re-scans from scratch every call — SignalChecker never
  /// needs to remember "a breakout happened, now watching for a retest"
  /// across cycles, since the breakout candle stays in the candle history
  /// and a later cycle's longer list naturally reaches the retest itself.
  /// The ONLY state SignalChecker keeps is which ranges already fired (see
  /// [OrbRange.key]), checked by the caller, not here.
  ///
  /// "Strictly ignore wicks/shadows" (explicit request): only a CANDLE
  /// CLOSE beyond the range counts, never an intrabar wick through it.
  ///
  /// Retest is now mandatory (2026-09-18, explicit request — the immediate,
  /// no-retest entry mode was removed): the breakout must be followed by a
  /// genuine retest — price trading back to touch the broken boundary and
  /// then closing beyond it again — before firing. A close all the way
  /// back through the range's FAR side invalidates the breakout outright
  /// (the thesis broke down entirely, not just pulled back) and no trigger
  /// is ever returned for this range again, even on a later call.
  ///
  /// Time-boxed to [deadline] (2026-09-24): candles at or past it are
  /// dropped BEFORE the scan, so both halves of the setup — the breakout
  /// and its retest — must complete inside the window. Filtering the
  /// candles rather than just checking the wall clock means a scan that
  /// runs late can't reach back and fire off a stale break either.
  OrbTrigger? findTrigger(List<Candle> candles5m, OrbRange range) {
    final expiresAt = deadline(range);
    final after = candles5m
        .where((c) => !c.time.isBefore(range.rangeEnd) && c.time.isBefore(expiresAt))
        .toList();
    if (after.isEmpty) return null;

    int? breakoutIndex;
    TradeDirection? direction;
    for (var i = 0; i < after.length; i++) {
      final c = after[i];
      if (c.close > range.high) {
        breakoutIndex = i;
        direction = TradeDirection.buy;
        break;
      }
      if (c.close < range.low) {
        breakoutIndex = i;
        direction = TradeDirection.sell;
        break;
      }
    }
    if (breakoutIndex == null) return null;

    final bullish = direction == TradeDirection.buy;
    final boundary = bullish ? range.high : range.low;
    for (var i = breakoutIndex + 1; i < after.length; i++) {
      final c = after[i];

      final invalidated = bullish ? c.close < range.low : c.close > range.high;
      if (invalidated) return null;

      final touchedBoundary = bullish ? c.low <= boundary : c.high >= boundary;
      if (!touchedBoundary) continue; // still extending away — no retest yet

      final resumedBreakout = bullish ? c.close > boundary : c.close < boundary;
      if (resumedBreakout) {
        return OrbTrigger(range: range, direction: direction!, entryCandle: c);
      }
      // Touched the boundary but closed back inside the range on this
      // candle — not yet a confirmed resumption; keep watching.
    }
    return null;
  }
}
