import 'dart:math';

import '../config/app_config.dart';
import '../models/candle.dart';
import '../models/pivot.dart';

/// The session ORB trades. Since 2026-10-09 (explicit request: "ضيف المحرك الخامس و قم بحذف ORB القديم") that is
/// ONLY the Asian open at [AppConfig.orbAsiaOpenUtcHour] (01:00 UTC — Shanghai/Hong Kong open, 09:00 in China, no
/// daylight-saving shifts). The old London and New York sessions were removed: across every replay of real MT5 history
/// they lost money on gold (ORB at 07:00/12:00/13:30 UTC was negative in both periods tested), while the 01:00 UTC range
/// was the one that held up in both.
enum OrbSession { asia }

extension OrbSessionInfo on OrbSession {
  String get label => switch (this) {
        OrbSession.asia => 'Asia',
      };

  int get startHourUtc => switch (this) {
        OrbSession.asia => AppConfig.orbAsiaOpenUtcHour,
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
  /// SignalChecker._consumedOrbRanges), so a new calendar day always starts a fresh key.
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

/// Asia Opening Range Breakout (rebuilt 2026-10-09 from the "Pat" ORB study) — deliberately ISOLATED from
/// TaEngine/IctEngine/ImpulseCorrectionEngine: it never reads an HTF zone, a swing pivot, or a structure bias, only
/// the raw 5M candles of the Asian open.
///
/// The rules: the range is the high/low (wicks included) of the first 15 minutes after 01:00 UTC; the first CLOSED
/// 5M candle beyond it decides the side; the entry waits for price to come back to the broken edge and close beyond
/// it again (the retest), and must happen before [AppConfig.orbEntryUntilUtcHour] (07:00 UTC). SignalChecker puts the
/// Stop Loss behind the range's far side and the Take Profit at [AppConfig.orbRiskRewardDefault] R.
///
/// Why this entry: replaying 16 weeks of real MT5 history (22.06-09.10.2026, stops limited to 20-200 pips, 1.5 pip
/// spread) the confirmed retest beat both a limit order at the edge and an entry at the first touch:
/// 42 trades, about 62-64 % winners, profit factor about 2.8, against about 1.7 for the limit order.
class OrbEngine {
  /// Builds today's Opening Range for [session] from [candles5m] — every
  /// CLOSED 5M candle whose open time falls in [session's start, start +
  /// [AppConfig.orbRangeMinutes]). Returns null while that window hasn't
  /// fully closed yet ([nowUtc] hasn't reached its end) or when the feed is
  /// missing candles inside it (a gap/outage right at the session open) — a
  /// range built from a partial window would be meaningless as tradeable
  /// structure. The required candle count is DERIVED from the configured
  /// window length rather than hard-coded.
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

  /// The instant [range] stops being tradeable — [AppConfig.orbEntryUntilUtcHour] (07:00 UTC) on the range's own
  /// day, i.e. the end of the Asian session, when London's open starts a different market. Exposed on the engine
  /// (rather than buried inside [findTrigger]) so SignalChecker can say so in its scan notes.
  DateTime deadline(OrbRange range) => DateTime.utc(
        range.rangeStart.year,
        range.rangeStart.month,
        range.rangeStart.day,
        AppConfig.orbEntryUntilUtcHour,
      );

  /// Scans the CLOSED 5M candles after [range] — up to its [deadline] —
  /// for a qualifying breakout.
  /// Stateless and re-scans from scratch every call — SignalChecker never
  /// needs to remember "a breakout happened, now watching for a retest"
  /// across cycles, since the breakout candle stays in the candle history
  /// and a later cycle's longer list naturally reaches the retest itself.
  /// The ONLY state SignalChecker keeps is which ranges already fired (see
  /// [OrbRange.key]), checked by the caller, not here.
  ///
  /// Only a CANDLE CLOSE beyond the range counts as the breakout, never an intrabar wick through it.
  ///
  /// The retest is mandatory: the breakout must be followed by price trading back to touch the broken edge and
  /// then closing beyond it again before firing. A close all the way back through the range's FAR side
  /// invalidates the breakout outright (the thesis broke down entirely, not just pulled back) and no trigger is
  /// ever returned for this range again, even on a later call.
  ///
  /// Time-boxed to [deadline]: candles at or past it are dropped BEFORE the scan, so both halves of the setup —
  /// the breakout and its retest — must complete inside the window. Filtering the candles rather than just
  /// checking the wall clock means a scan that runs late can't reach back and fire off a stale break either.
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
