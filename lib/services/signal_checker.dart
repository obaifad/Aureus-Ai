import 'package:flutter/foundation.dart' show visibleForTesting;
import 'dart:math';
import '../config/app_config.dart';
import '../models/candle.dart';
import '../models/pivot.dart';
import '../models/trade_setup.dart';
import 'ai_engine.dart';
import 'app_logger.dart';
import 'connection_status_service.dart';
import 'data_service.dart';
import 'history_store.dart';
import 'breakout_momentum_engine.dart';
import 'approval_service.dart';
import 'broker_reconciler.dart';
import 'dxy_filter_service.dart';
import 'pending_store.dart';
import 'strategy_config_service.dart';
import 'ict_engine.dart';
import 'impulse_correction_engine.dart';
import 'market_regime_guard.dart';
import 'mt5_trading_service.dart';
import 'news_calendar_service.dart';
import 'notifier_service.dart';
import 'orb_engine.dart';
import 'price_alert_service.dart';
import 'risk_engine.dart';
import 'ta_engine.dart';
import 'zone_bounce_engine.dart';

class _CachedCandles {
  final DateTime fetchedAt;
  final List<Candle> candles;
  final FeedSource? source; // null in mock mode
  const _CachedCandles(this.fetchedAt, this.candles, this.source);
}

/// The market-dynamics safety layers' verdicts for one scan, each with the mode it runs in.
class _Regime {
  final GuardMode impulseMode;
  final ImpulseVerdict impulse;
  final GuardMode chaosMode;
  final ChaosVerdict chaos;
  const _Regime({required this.impulseMode, required this.impulse, required this.chaosMode, required this.chaos});

  bool get chaosActive => chaosMode != GuardMode.off && chaos.stressed;
}

/// [isFresh] is false when these candles came from the cache after a failed
/// refresh (stale-while-revalidate).
typedef _CandleFetch = ({List<Candle> candles, bool isFresh, FeedSource? source});

/// Result of a single check cycle: a human-readable status and the
/// setup(s) found this cycle, if any — one per independent strategy tier
/// (legacy/ICT/ICI/ORB) that fired. Legacy/ICT/ICI are always evaluated
/// against CLOSED 15M candles; ORB (when enabled) against CLOSED 5M
/// candles instead — see [SignalChecker._evaluateOrbTrigger]. Setups are
/// NOT yet AI-annotated, notified or persisted — MonitorEngine does that
/// after de-duplicating them against the stored history.
class SignalCheckResult {
  final String status;
  final List<TradeSetup> setups;
  final FeedSource? feed;
  final double? livePrice;
  const SignalCheckResult({required this.status, this.setups = const [], this.feed, this.livePrice});
}

/// Drops the still-forming candle (if any): a candle is closed once its open
/// time + timeframe is at or before [nowUtc]. Every strategy evaluates CLOSED
/// candles only, so a Pinbar/Engulfing that appears mid-candle and then
/// disappears before the close can no longer fire a signal (repainting).
List<Candle> closedCandlesOnly(List<Candle> candles, int timeframeMinutes, DateTime nowUtc) {
  if (candles.isEmpty) return candles;
  final last = candles.last;
  final closesAt = last.time.toUtc().add(Duration(minutes: timeframeMinutes));
  return closesAt.isAfter(nowUtc) ? candles.sublist(0, candles.length - 1) : candles;
}

/// The Strict Top-Down Multi-Timeframe pipeline:
///
///  1. 4H also sets the trend bias (context, alongside 1H — see step 4).
///  2. 15M + 1H + 4H structure — S/R, Supply/Demand, trendlines
///     (TaEngine.buildHtfZones, 4H added 2026-09-10) — is the ONLY source
///     of tradeable "Key Zones". 1M/5M are never used to seed a new zone.
///     Higher-timeframe zones aren't pooled as equals: TaEngine.
///     findNearestZone gives 4H/1H zones priority over a same-ish-distance
///     15M one ("الأزمنة الأعلى خطوطها هي الأقوى").
///  3. 15M is the ONLY execution timeframe (2026-09-14, "completely
///     disable Scalping strategies" — 5M was previously primary with a 1M
///     scalping fallback; both were removed along with every 1M/5M candle
///     fetch anywhere in this pipeline). A setup triggers ONLY on the HTF
///     Retest Protocol (2026-09-18 — see TaEngine.findExecutionTrigger: HTF
///     zone -> strict 1H+4H swing-structure bias -> price back INTO the
///     zone after breaking through it -> Liquidity Sweep -> Market
///     Structure Shift -> a decisive entry candle, with the Stop Loss
///     behind the swept swing and the Take Profit at the next
///     liquidity/HTF target). The standalone Momentum/Breakout fallback
///     path (firing on an expansion candle near any zone when the protocol
///     found nothing) was removed the same day, explicit request — no
///     Top-Down entry without a confirmed retest anymore. The old
///     "Interest Area" proximity-to-zone requirement
///     (AppConfig.interestZoneBufferDollars) was REMOVED as an eligibility
///     gate on 2026-09-14 (explicit request — the app sat idle for hours
///     whenever price drifted just outside the old $5 buffer); the
///     constant still exists and is used to build Confluence Zones, to
///     measure a decisive break through a zone in the Retest Protocol, and
///     to label a trigger's zone as "in buffer" vs an Order Flow
///     penetration in the logs — it no longer blocks a trigger from firing
///     regardless of how far price currently sits from the nearest HTF
///     zone. (A third path — 15M Higher Low / Lower High Absorption,
///     SetupType.absorption15m — used to fire here when both of the above
///     found nothing; retired 2026-09-18, explicit request. Its pattern
///     classifier, TaEngine.classifyStrongAbsorption, lives on as a shared
///     confirmation check for the HTF Retest Protocol and
///     ImpulseCorrectionEngine.)
///  4. Every triggered setup is priced by RiskEngine (SL is always the
///     organic structural distance — no minimum-SL floor at the RiskEngine
///     level, 2026-09-10; a blanket AppConfig.minStopLossPips/
///     minTakeProfitPips REJECTION floor was added on top 2026-09-14, see
///     _rejectsMinStopLossDistance/_rejectsMinTakeProfitDistance), then
///     must pass, in order: those two distance filters, a Scalping
///     Timeframe Guard (_rejectsScalpingTimeframe — dead in practice now
///     that 1M/5M are never fetched, kept as an explicit defense-in-depth
///     check), a Liquidity-Target R:R floor for HTF Retest setups only
///     (AppConfig.htfRetestMinRiskReward — their TP sits at real structure
///     rather than a fixed multiple, so too little room means no trade),
///     an HTF Trend Alignment gate — setup direction must not oppose a
///     clear 1H OR 4H bias (2026-09-10: checks both now, not just 4H),
///     UNLESS it's anchored to a larger-timeframe (1H) zone — an HTF Retest
///     never gets that exemption (2026-09-18: the protocol already gates on
///     structure bias, so exempting it from momentum bias defeated the
///     gate) — a Trendline Clear-Path gate (2026-09-10: a
///     Trendline-sourced trigger is rejected if another HTF zone sits
///     between Entry and TP), Rule 2
///     (staleness), Rule 4 (Confluence Score >= AppConfig.
///     minConfluenceScore — minConfluenceScoreScalping/70 no longer
///     applies to anything since Scalping was disabled), Rule 3
///     (directional debounce) — reject at the first rule it fails.
///
/// A one-time "High-Impact News Alert" notification (see
/// news_calendar_service.dart / NotifierService.sendNewsAlert) still fires
/// 15 minutes before every High-Impact USD calendar event (CPI, PPI, NFP,
/// FOMC, Fed Rate Decisions...) — purely informational now: the News
/// Freeze that used to block setup generation around these events was
/// removed (2026-09-09), so signals can fire during the news window too.
///
/// This trades signal frequency for signal quality on purpose — the
/// opposite of the earlier "scan every timeframe independently, widen
/// every threshold" tuning. Fewer, more deliberate setups.
class SignalChecker {
  final TaEngine _ta = TaEngine();
  final IctEngine _ict = IctEngine();
  final ImpulseCorrectionEngine _ici = ImpulseCorrectionEngine();
  final OrbEngine _orb = OrbEngine();
  final ZoneBounceEngine _zoneBounce = ZoneBounceEngine();
  final BreakoutMomentumEngine _breakout = BreakoutMomentumEngine();
  final ImpulseDetector _impulse = const ImpulseDetector();
  final ChaosDetector _chaos = const ChaosDetector();
  final RiskEngine _risk;

  /// Injectable clock and data source (2026-09-25) — both default to the
  /// real ones, so the app behaves exactly as before. They exist so the
  /// REAL [check] pipeline can be replayed over historical candles (see
  /// test/_backtest_all.dart) instead of a re-implementation that could
  /// drift from it: every debounce, cooldown, session filter and outcome
  /// sweep below reads [_now] rather than the wall clock.
  final DateTime Function() _now;
  final DataService Function() _newDataService;

  SignalChecker({
    DataService Function()? dataServiceFactory,
    DateTime Function()? clock,
    Mt5TradingService? trading,
  })  : _now = clock ?? DateTime.now,
        _newDataService = dataServiceFactory ?? DataService.new,
        _risk = RiskEngine(clock: clock),
        _trading = trading ?? Mt5TradingService();
  final AiEngine _ai = AiEngine();
  final NotifierService _notifier = NotifierService();
  final PriceAlertService _alerts = PriceAlertService();
  final NewsCalendarService _newsCalendar = NewsCalendarService();
  final DxyFilterService _dxy = DxyFilterService();
  final Mt5TradingService _trading;
  late final BrokerReconciler _reconciler = BrokerReconciler(trading: _trading, clock: _now);
  late final ApprovalService _approval = ApprovalService(trading: _trading, clock: _now);

  /// Engine debounce state as it was BEFORE a proposal fired, kept per proposal so a
  /// rejected / expired / blocked one can hand its engine back exactly as it was.
  final Map<String, Map<String, Object?>> _pendingPreState = {};

  /// An engine whose proposal was not traded stays quiet until this time, so the
  /// very same still-valid setup cannot re-propose itself on the next scan.
  final Map<String, DateTime> _engineCooldownUntil = {};

  // 15M is the only timeframe that ever fires now (2026-09-14 — was 5M
  // before Scalping strategies were disabled), so a single "last signaled
  // candle" is enough debounce state (no more per-timeframe map).
  DateTime? _lastSignalCandleTime;

  // Rule 3 — Directional Debounce: the direction/time of the most recently
  // emitted signal, so an opposing signal within
  // AppConfig.directionalDebounceWindow is suppressed even across cycles.
  TradeDirection? _lastSignalDirection;
  DateTime? _lastSignalDirectionTime;

  // Per-HTF-Zone Cooldown: once a signal fires for a specific HTF zone,
  // suppress a duplicate alert for that SAME zone within
  // AppConfig.directionalDebounceWindow, even if it is the same direction —
  // distinct from Rule 3 above, which only guards against an OPPOSING
  // direction. Keyed by zone source + price so a genuinely new zone (or the
  // same zone renegotiated at a different price after structure rebuilds)
  // is never blocked.
  final Map<String, DateTime> _lastZoneSignalTime = {};

  // ICT/Smart-Money-Concepts strategy tier (ict_engine.dart, 2026-09-12) —
  // the SAME three kinds of debounce state as above, kept entirely
  // separate so this strategy can fire independently of (and doesn't get
  // blocked by) the legacy strategy's own state, and vice versa.
  DateTime? _lastIctSignalCandleTime;
  TradeDirection? _lastIctSignalDirection;
  DateTime? _lastIctSignalDirectionTime;
  final Map<String, DateTime> _lastIctZoneSignalTime = {};

  // Impulse-Correction-Impulse strategy tier (impulse_correction_engine.
  // dart, 2026-09-13) — same independent debounce pattern as ICT above.
  DateTime? _lastIciSignalCandleTime;
  TradeDirection? _lastIciSignalDirection;
  DateTime? _lastIciSignalDirectionTime;
  final Map<String, DateTime> _lastIciZoneSignalTime = {};

  // Opening Range Breakout strategy tier (orb_engine.dart, 2026-09-18) —
  // its debounce is structurally different from the other three: ORB's own
  // "Single Trade per Range" requirement (explicit request) means the
  // range itself, not a rolling time window, is the unit of debounce. Once
  // a range's key (see OrbRange.key — session + calendar day) is in this
  // set, OrbEngine.findTrigger is never even given the chance to re-fire
  // for it again, retest or not, for the rest of that day.
  final Set<String> _consumedOrbRanges = {};

  // Breakout/Momentum strategy tier (breakout_momentum_engine.dart,
  // 2026-09-18) — the SAME three kinds of debounce state ICT/ICI keep
  // (candle/direction/zone), entirely independent of every other tier's.
  // Unlike ORB, a level here (e.g. an HTF Support/Resistance zone) can stay
  // valid and keep re-triggering for a long time, so this uses the normal
  // time-window zone-cooldown rather than a single-shot "consumed" flag.
  DateTime? _lastBreakoutSignalCandleTime;
  TradeDirection? _lastBreakoutSignalDirection;
  DateTime? _lastBreakoutSignalDirectionTime;
  final Map<String, DateTime> _lastBreakoutZoneSignalTime = {};

  // Ranging Market Module — Zone Bounce Protocol (zone_bounce_engine.dart,
  // 2026-09-25) — the same candle/direction/zone debounce trio ICT, ICI and
  // Breakout keep, entirely independent of all of them. A range boundary
  // stays valid and can legitimately be bounced off repeatedly, so this
  // uses the rolling zone cooldown rather than ORB's single-shot
  // "consumed" set.
  DateTime? _lastZoneBounceSignalCandleTime;
  TradeDirection? _lastZoneBounceSignalDirection;
  DateTime? _lastZoneBounceSignalDirectionTime;
  final Map<String, DateTime> _lastZoneBounceZoneSignalTime = {};

  // Volatility & Chaos Filter baseline (market_regime_guard.dart, 2026-10-07): what each 15-minute slot
  // of the day normally looks like over the last ~20 trading days. It changes slowly, so it is rebuilt at
  // most once an hour from ONE long history fetch (the bridge's 2000-candle cap is ~21 trading days of
  // 15M). After a failed fetch the stale baseline is kept (better than none) and the next attempt waits.
  VolatilityBaseline? _volatilityBaseline;
  DateTime? _baselineRetryAfter;
  static const Duration _baselineTtl = Duration(minutes: 60);
  static const Duration _baselineRetryDelay = Duration(minutes: 10);
  static const int _baselineCandleCount = 2000;

  /// Guard messages already logged (a verdict that holds for many 30-second scans is logged once).
  final Set<String> _loggedGuardKeys = {};

  // Per-timeframe candle cache — persists across check() cycles (this
  // instance lives for the whole monitoring session). An entry is reused
  // only while BOTH its TTL hasn't expired AND no candle boundary of that
  // timeframe has passed since it was fetched — so a freshly closed 15M/1H/
  // 4H candle is always picked up on the very next cycle, while 1H/4H are
  // not re-downloaded every 30 seconds in between.
  final Map<int, _CachedCandles> _candleCache = {};
  static const Map<int, Duration> _cacheTtl = {
    // Only ever populated while AppConfig.useOrb is true (see [check]) — a
    // 5M candle closes every 5 minutes, so this needs a materially shorter
    // TTL than 15M's to still catch one within the same ~30s poll cadence.
    5: Duration(seconds: 25),
    15: Duration(seconds: 55),
    60: Duration(minutes: 15),
    240: Duration(minutes: 60),
  };

  /// Which engines were enabled last scan — used to drop an engine's
  /// debounce state the moment it is switched off.
  final Map<String, bool> _engineWasEnabled = {};

  bool _engineEnabled(String id) => switch (id) {
        EngineIds.htfRetest => AppConfig.useHtfRetest,
        EngineIds.ict => AppConfig.useIct,
        EngineIds.ici => AppConfig.useIci,
        EngineIds.orb => AppConfig.useOrb,
        EngineIds.breakout => AppConfig.useBreakoutMomentum,
        EngineIds.rangeBounce => AppConfig.enableRangingBounceMode,
        _ => true,
      };

  /// Called once per scan after the config snapshot is promoted. A disabled
  /// engine is never evaluated, so it cannot burn a cooldown; this also
  /// clears the cooldowns it already held when it is switched OFF. ORB is
  /// deliberately left alone: its "one trade per range per day" is a
  /// strategy rule, not an in-flight debounce.
  void _syncEngineStates() {
    for (final id in EngineIds.all) {
      final enabled = _engineEnabled(id);
      if (_engineWasEnabled[id] == true && !enabled) {
        _resetEngineState(id);
        _log('Engine $id switched OFF — its cooldown state was cleared');
      }
      _engineWasEnabled[id] = enabled;
    }
  }

  void _resetEngineState(String id) {
    switch (id) {
      case EngineIds.htfRetest:
        _lastSignalCandleTime = null;
        _lastSignalDirection = null;
        _lastSignalDirectionTime = null;
        _lastZoneSignalTime.clear();
      case EngineIds.ict:
        _lastIctSignalCandleTime = null;
        _lastIctSignalDirection = null;
        _lastIctSignalDirectionTime = null;
        _lastIctZoneSignalTime.clear();
      case EngineIds.ici:
        _lastIciSignalCandleTime = null;
        _lastIciSignalDirection = null;
        _lastIciSignalDirectionTime = null;
        _lastIciZoneSignalTime.clear();
      case EngineIds.breakout:
        _lastBreakoutSignalCandleTime = null;
        _lastBreakoutSignalDirection = null;
        _lastBreakoutSignalDirectionTime = null;
        _lastBreakoutZoneSignalTime.clear();
      case EngineIds.rangeBounce:
        _lastZoneBounceSignalCandleTime = null;
        _lastZoneBounceSignalDirection = null;
        _lastZoneBounceSignalDirectionTime = null;
        _lastZoneBounceZoneSignalTime.clear();
    }
  }

  bool _cooling(String id) {
    final until = _engineCooldownUntil[id];
    if (until == null) return false;
    if (!_now().isBefore(until)) {
      _engineCooldownUntil.remove(id);
      return false;
    }
    return true;
  }

  /// An engine runs only if it is switched on AND not cooling down after a
  /// proposal that was not traded.
  bool _runnable(String id, bool enabled) => enabled && !_cooling(id);

  void _coolEngine(String id, Duration duration) => _engineCooldownUntil[id] = _now().add(duration);

  /// A copy of an engine's debounce state (what it remembers having signalled).
  Map<String, Object?> _captureEngineState(String id) => switch (id) {
        EngineIds.htfRetest => {
            'candle': _lastSignalCandleTime,
            'dir': _lastSignalDirection,
            'dirTime': _lastSignalDirectionTime,
            'zones': Map<String, DateTime>.of(_lastZoneSignalTime),
          },
        EngineIds.ict => {
            'candle': _lastIctSignalCandleTime,
            'dir': _lastIctSignalDirection,
            'dirTime': _lastIctSignalDirectionTime,
            'zones': Map<String, DateTime>.of(_lastIctZoneSignalTime),
          },
        EngineIds.ici => {
            'candle': _lastIciSignalCandleTime,
            'dir': _lastIciSignalDirection,
            'dirTime': _lastIciSignalDirectionTime,
            'zones': Map<String, DateTime>.of(_lastIciZoneSignalTime),
          },
        EngineIds.breakout => {
            'candle': _lastBreakoutSignalCandleTime,
            'dir': _lastBreakoutSignalDirection,
            'dirTime': _lastBreakoutSignalDirectionTime,
            'zones': Map<String, DateTime>.of(_lastBreakoutZoneSignalTime),
          },
        EngineIds.rangeBounce => {
            'candle': _lastZoneBounceSignalCandleTime,
            'dir': _lastZoneBounceSignalDirection,
            'dirTime': _lastZoneBounceSignalDirectionTime,
            'zones': Map<String, DateTime>.of(_lastZoneBounceZoneSignalTime),
          },
        EngineIds.orb => {'consumed': Set<String>.of(_consumedOrbRanges)},
        _ => const <String, Object?>{},
      };

  /// Puts an engine's debounce state back to [state]. Used when a signal the
  /// engine fired turned out not to be proposed or traded, so the engine does
  /// not stay "used up" for something the owner never got to decide on.
  void _restoreEngineState(String id, Map<String, Object?> state) {
    if (state.isEmpty) return;
    DateTime? candle() => state['candle'] as DateTime?;
    TradeDirection? dir() => state['dir'] as TradeDirection?;
    DateTime? dirTime() => state['dirTime'] as DateTime?;
    Map<String, DateTime> zones() => state['zones'] as Map<String, DateTime>;
    switch (id) {
      case EngineIds.htfRetest:
        _lastSignalCandleTime = candle();
        _lastSignalDirection = dir();
        _lastSignalDirectionTime = dirTime();
        _lastZoneSignalTime
          ..clear()
          ..addAll(zones());
      case EngineIds.ict:
        _lastIctSignalCandleTime = candle();
        _lastIctSignalDirection = dir();
        _lastIctSignalDirectionTime = dirTime();
        _lastIctZoneSignalTime
          ..clear()
          ..addAll(zones());
      case EngineIds.ici:
        _lastIciSignalCandleTime = candle();
        _lastIciSignalDirection = dir();
        _lastIciSignalDirectionTime = dirTime();
        _lastIciZoneSignalTime
          ..clear()
          ..addAll(zones());
      case EngineIds.breakout:
        _lastBreakoutSignalCandleTime = candle();
        _lastBreakoutSignalDirection = dir();
        _lastBreakoutSignalDirectionTime = dirTime();
        _lastBreakoutZoneSignalTime
          ..clear()
          ..addAll(zones());
      case EngineIds.rangeBounce:
        _lastZoneBounceSignalCandleTime = candle();
        _lastZoneBounceSignalDirection = dir();
        _lastZoneBounceSignalDirectionTime = dirTime();
        _lastZoneBounceZoneSignalTime
          ..clear()
          ..addAll(zones());
      case EngineIds.orb:
        _consumedOrbRanges
          ..clear()
          ..addAll(state['consumed'] as Set<String>);
    }
  }

  /// A proposal ended without a trade: hand its engine back and keep it quiet for a while.
  void _releaseApproval(ReleasedApproval released, StrategyConfigSnapshot cfg) {
    final id = released.approval.engineId;
    final snapshot = _pendingPreState.remove(released.approval.uid);
    if (snapshot != null) _restoreEngineState(id, snapshot);
    final decided = released.state == 'rejected' || released.state == 'expired';
    final cooldown = decided ? Duration(minutes: cfg.rejectCooldownMinutes) : const Duration(minutes: 2);
    _coolEngine(id, cooldown);
    _log('📲 Proposal ${released.approval.setup.setupLabel} ended: ${released.state} — $id released, '
        'quiet for ${cooldown.inMinutes} min');
  }

  @visibleForTesting
  int debugPriorityRank(TradeSetup setup) => _enginePriorityRank(setup);

  /// The two evaluators the market-safety layers live in, callable with hand-built candles (the full
  /// scan needs a whole multi-timeframe market to make either engine fire).
  @visibleForTesting
  Future<TradeSetup?> debugEvaluateZoneBounce({
    required List<Candle> m15,
    required List<HtfZone> htfZones,
    required List<String> notes,
    required double livePrice,
    ImpulseVerdict impulse = ImpulseVerdict.none,
    GuardMode impulseMode = GuardMode.off,
  }) =>
      _evaluateZoneBounceTrigger(
        m15: m15,
        htfZones: htfZones,
        htfStructureBias: null,
        notes: notes,
        livePrice: livePrice,
        impulse: impulse,
        impulseMode: impulseMode,
      );

  @visibleForTesting
  Future<TradeSetup?> debugEvaluateIct({
    required List<Candle> m15,
    required List<Candle> h1,
    required List<Candle> h4,
    required List<HtfZone> htfZones,
    required List<String> notes,
    required double livePrice,
  }) =>
      _evaluateIctTrigger(m15: m15, h1: h1, h4: h4, htfZones: htfZones, notes: notes, livePrice: livePrice);

  @visibleForTesting
  Future<TradeSetup?> debugEvaluateOrb({
    required List<Candle> candles5m,
    required TradeDirection? bias1h,
    required DateTime nowUtc,
    required List<String> notes,
    required double livePrice,
  }) =>
      _evaluateOrbTrigger(candles5m: candles5m, bias1h: bias1h, nowUtc: nowUtc, notes: notes, livePrice: livePrice);

  @visibleForTesting
  Map<String, Object?> debugCaptureState(String id) => _captureEngineState(id);

  @visibleForTesting
  void debugRestoreState(String id, Map<String, Object?> state) => _restoreEngineState(id, state);

  @visibleForTesting
  bool debugCooling(String id) => _cooling(id);

  @visibleForTesting
  void debugCool(String id, Duration duration) => _coolEngine(id, duration);

  /// Marks [id] as having just fired, the way a real signal would.
  @visibleForTesting
  void debugMarkFired(String id) {
    final now = _now();
    switch (id) {
      case EngineIds.htfRetest:
        _lastSignalCandleTime = now;
        _lastSignalDirection = TradeDirection.buy;
        _lastSignalDirectionTime = now;
        _lastZoneSignalTime['zone'] = now;
      case EngineIds.rangeBounce:
        _lastZoneBounceSignalCandleTime = now;
        _lastZoneBounceSignalDirection = TradeDirection.sell;
        _lastZoneBounceSignalDirectionTime = now;
        _lastZoneBounceZoneSignalTime['zone'] = now;
      case EngineIds.orb:
        _consumedOrbRanges.add('london|fired');
    }
  }

  /// Prints the reasoning behind every accept/reject decision this cycle
  /// makes, routed through AppLogger (persisted, visible in System Logs from
  /// either isolate, and in `adb logcat`).
  void _log(String message) => AppLogger.log(message);

  /// Logs [message] the first time [key] is seen. A guard verdict that holds across many 30-second scans
  /// (the same candle, the same impulse) is one event, not one line per scan.
  void _logGuardOnce(String key, String message) {
    if (_loggedGuardKeys.length > 400) _loggedGuardKeys.clear();
    if (_loggedGuardKeys.add(key)) _log(message);
  }

  /// The 20-day time-of-day volatility baseline, rebuilt at most once an hour. Null when none could be
  /// built — the Chaos Filter then has no opinion (it never blocks on a failure).
  Future<VolatilityBaseline?> _loadVolatilityBaseline(DataService dataService, DateTime nowUtc, int days) async {
    final cached = _volatilityBaseline;
    if (cached != null && cached.days == days && nowUtc.difference(cached.builtAt) < _baselineTtl) return cached;
    final retryAfter = _baselineRetryAfter;
    if (retryAfter != null && nowUtc.isBefore(retryAfter)) return cached;
    try {
      final history = await dataService.getCandles(timeframeMinutes: AppConfig.tfM15, count: _baselineCandleCount);
      final closed = closedCandlesOnly(history, AppConfig.tfM15, nowUtc);
      if (closed.length < 200) {
        _baselineRetryAfter = nowUtc.add(_baselineRetryDelay);
        _log('Volatility baseline: only ${closed.length} closed 15M candles available — chaos filter has no opinion');
        return cached;
      }
      final built = VolatilityBaseline.build(closed, nowUtc: nowUtc, days: days);
      _volatilityBaseline = built;
      _baselineRetryAfter = null;
      _log('Volatility baseline built from ${closed.length} closed 15M candles (median per time-of-day slot, '
          'last $days trading days)');
      return built;
    } catch (e) {
      _baselineRetryAfter = nowUtc.add(_baselineRetryDelay);
      _log('Volatility baseline unavailable ($e) — ${cached == null ? 'chaos filter has no opinion' : 'keeping the previous one'}');
      return cached;
    }
  }

  /// Evaluates the Fast-Impulse Guard and the Chaos Filter for this scan. Each is only evaluated when
  /// its mode is not `off`; the impulse guard only when Range Bounce — the one engine it restricts — is
  /// enabled. Any failure degrades to "no opinion": a safety layer must not be able to break the scan.
  Future<_Regime> _assessRegime({
    required DataService dataService,
    required List<Candle> m15,
    required List<Candle> m15Raw,
    required List<Candle> m5,
    required DateTime nowUtc,
    required bool bridgeLive,
  }) async {
    final impulseMode = AppConfig.impulseGuardMode;
    final chaosMode = AppConfig.chaosFilterMode;

    var impulse = ImpulseVerdict.none;
    if (impulseMode != GuardMode.off && AppConfig.enableRangingBounceMode) {
      try {
        impulse = _impulse.assess(m15: m15, m5: m5, nowUtc: nowUtc, params: ImpulseParams.current());
      } catch (e) {
        _log('Fast-Impulse Guard skipped this scan: $e');
      }
    }

    var chaos = ChaosVerdict.unavailable;
    if (chaosMode != GuardMode.off && !AppConfig.useMockData) {
      try {
        final params = ChaosParams.current();
        final baseline = await _loadVolatilityBaseline(dataService, nowUtc, params.baselineDays);
        final liveSpread = bridgeLive ? await _trading.getSpreadPips() : null;
        final newest = m15Raw.isEmpty ? null : m15Raw.last;
        final forming = newest != null && newest.time.toUtc().add(const Duration(minutes: AppConfig.tfM15)).isAfter(nowUtc)
            ? newest
            : null;
        chaos = _chaos.assess(
          closed15m: m15,
          forming: forming,
          baseline: baseline,
          nowUtc: nowUtc,
          liveSpreadPips: liveSpread,
          params: params,
        );
      } catch (e) {
        _log('Chaos filter skipped this scan: $e');
      }
    }
    return _Regime(impulseMode: impulseMode, impulse: impulse, chaosMode: chaosMode, chaos: chaos);
  }

  /// Minimum Take-Profit Distance Filter (2026-09-14, explicit request;
  /// threshold documented on AppConfig.minTakeProfitPips) — shared by all
  /// four strategy evaluators so every path is held to the same floor.
  bool _rejectsMinTakeProfitDistance(TradeSetup setup) {
    final tpPips = (setup.takeProfit - setup.entry).abs() / TradeSetup.dollarsPerPip;
    if (tpPips < AppConfig.minTakeProfitPips) {
      _log('Signal skipped: TP distance (${tpPips.toStringAsFixed(1)} pips) is below the '
          '${AppConfig.minTakeProfitPips.toStringAsFixed(0)} pips threshold.');
      return true;
    }
    return false;
  }

  /// Minimum Stop-Loss Distance Filter (2026-09-14, explicit request;
  /// threshold documented on AppConfig.minStopLossPips).
  bool _rejectsMinStopLossDistance(TradeSetup setup) {
    final slPips = setup.riskDollars / TradeSetup.dollarsPerPip;
    if (slPips < AppConfig.minStopLossPips) {
      _log('Signal skipped: SL distance (${slPips.toStringAsFixed(1)} pips) is below the '
          '${AppConfig.minStopLossPips.toStringAsFixed(0)} pips minimum — too tight for normal market noise.');
      return true;
    }
    return false;
  }

  /// Maximum Stop-Loss Distance Filter (2026-09-17, explicit request:
  /// never open a trade whose SL sits further than
  /// AppConfig.maxStopLossPips from Entry).
  bool _rejectsMaxStopLossDistance(TradeSetup setup) {
    final slPips = setup.riskDollars / TradeSetup.dollarsPerPip;
    if (slPips > AppConfig.maxStopLossPips) {
      _log('Signal skipped: SL distance (${slPips.toStringAsFixed(1)} pips) exceeds the '
          '${AppConfig.maxStopLossPips.toStringAsFixed(0)} pips maximum — trade not opened.');
      return true;
    }
    return false;
  }

  /// Rule 2 — Signal Staleness: shared by all four strategies.
  bool _rejectsStaleDrift(TradeSetup setup, double livePrice) {
    final drift = (livePrice - setup.entry).abs();
    if (drift > AppConfig.maxStalePriceDriftDollars) {
      _log('${setup.setupLabel} rejected — live price \$${livePrice.toStringAsFixed(2)} drifted '
          '\$${drift.toStringAsFixed(2)} from Entry \$${setup.entry.toStringAsFixed(2)} '
          '(> \$${AppConfig.maxStalePriceDriftDollars} max)');
      return true;
    }
    return false;
  }

  /// Scalping Timeframe Guard — defense-in-depth only; no Top-Down/ICT/ICI
  /// trigger is ever given 1M/5M candles (2026-09-14). Not applied to the
  /// ORB or Breakout/Momentum tiers (see _evaluateOrbTrigger /
  /// _evaluateBreakoutTrigger), whose whole point is a 5M execution
  /// timeframe by explicit design, not an accidental scalping leak.
  bool _rejectsScalpingTimeframe(String triggerTimeframeLabel) {
    if (triggerTimeframeLabel == '1M' || triggerTimeframeLabel == '5M') {
      _log('Scalping setup ignored (Timeframe < 15M).');
      return true;
    }
    return false;
  }

  /// DXY Correlation Filter (2026-09-18, explicit request) — shared by
  /// every strategy tier, checked right before each one's own final
  /// debounce-state mutation so a setup DXY blocks never consumes that
  /// tier's candle/zone/directional cooldown for an opportunity that never
  /// actually fired. See DxyFilterService's own doc comment for why every
  /// failure mode there resolves to allow, never to block.
  Future<bool> _passesDxyFilter(
    TradeSetup setup,
    String triggerInfo,
    List<String> notes,
    String engineId,
  ) async {
    // Per-engine override from the bridge config: `off`/`exempt` skip the
    // filter for this engine only. Null (no config) keeps today's behaviour.
    final engineMode = StrategyConfig.instance.current.engineDxyMode(engineId);
    if (engineMode == 'off' || engineMode == 'exempt') return true;
    final confirmed = await _dxy.confirms(setup.direction);
    if (!confirmed) {
      notes.add('$triggerInfo | rejected: DXY Correlation Filter — DXY is currently '
          '${setup.direction == TradeDirection.buy ? "bullish" : "bearish"}, opposing this '
          '${setup.directionLabel}');
      _log('Setup rejected by DXY Correlation Filter — ${setup.directionLabel} XAUUSD opposed by the DXY trend');
    }
    return confirmed;
  }

  /// Engine Priority Resolution (2026-09-20, explicit request): when more
  /// than one of the 5 engines fires in the same cycle, only the setup from
  /// the highest-ranked engine here survives — lower index wins. Built-in
  /// hierarchy (used when the bridge config has no priorities; it matches the
  /// bridge default): Top-Down > ICT > ICI > Range Bounce > ORB > Breakout —
  /// deliberately NOT alphabetical/declaration order.
  static const List<StrategyFamily> _enginePriorityOrder = [
    StrategyFamily.topDown,
    StrategyFamily.ict,
    StrategyFamily.ici,
    // Ranging Market Module. It can only fire while there is NO clear HTF bias, when the
    // trend engines are least likely to have fired. Every family MUST be present:
    // _enginePriorityRank uses indexOf, and a family missing from this list would rank
    // -1 and silently outrank every other engine.
    StrategyFamily.rangingBounce,
    StrategyFamily.orb,
    StrategyFamily.breakout,
  ];

  /// Rank of a setup's engine when several fire at once (lower wins). Follows the
  /// priorities in the bridge config when present, else the built-in order.
  int _enginePriorityRank(TradeSetup setup) {
    final family = setup.setupType.strategyFamily;
    return StrategyConfig.instance.current.enginePriority(EngineIds.forFamily(family)) ??
        _enginePriorityOrder.indexOf(family) + 1;
  }

  /// Logs which zone is currently closest when no legacy trigger formed.
  void _logNoTrigger(double livePrice, List<HtfZone> htfZones) {
    final nearest = _ta.findNearestZone(htfZones, livePrice);
    if (nearest == null) return;
    final nearestDist = (livePrice - nearest.price).abs();
    const effectiveBuffer = AppConfig.interestZoneBufferDollars + AppConfig.interestZoneToleranceDollars;
    final withinBuffer = nearestDist <= effectiveBuffer;
    final bufferPips = (effectiveBuffer * 10).round();
    final rangeLabel = withinBuffer ? 'Within ${bufferPips}p Buffer' : '\$${nearestDist.toStringAsFixed(2)} away';
    _log('🔍 Price \$${livePrice.toStringAsFixed(2)} | Zone \$${nearest.price.toStringAsFixed(2)} '
        '($rangeLabel) | Searching for a confirmed Retest...');
  }

  // ---------------------------------------------------------------------
  // Trade Outcome Watcher
  // ---------------------------------------------------------------------

  /// Closes every OPEN persisted setup that [evaluate] reports as crossed,
  /// via HistoryStore (reload → modify → save, serialized), then notifies
  /// once per closed trade. Returns true if anything closed.
  Future<bool> _sweepOpenTrades(
    ({TradeOutcome outcome, double exitPrice})? Function(TradeSetup setup) evaluate,
  ) async {
    final closed = <TradeSetup>[];
    final movedToBreakEven = <TradeSetup>[];
    try {
      await HistoryStore.mutate((history) {
        for (final setup in history) {
          if (setup.outcome != TradeOutcome.open) continue;
          // Break-Even Trigger (2026-09-17, DISABLED 2026-09-24): while
          // AppConfig.breakEvenEnabled is true, evaluate() is passed
          // updateBreakEven, so reaching 1:1 R:R flips the setup's own
          // breakEvenActive flag — the SL in force becomes Entry from
          // then on, while the TP stays at the original R:R. The flag
          // change must be persisted even on cycles where nothing closed.
          // With the flag off (the current default — "لا تحرك الستوب
          // لنقطة الدخول ابدا") nothing ever arms it, so activeStopLoss
          // stays the original structural Stop Loss for the whole life of
          // the trade and [movedToBreakEven] is always empty: no local
          // flip, no Broker Sync SL modify, no "0.0 pips" outcome. This
          // whole block is then inert rather than removed, so re-enabling
          // the flag restores the old behaviour with no code change.
          final wasBreakEven = setup.breakEvenActive;
          final result = evaluate(setup);
          if (setup.breakEvenActive && !wasBreakEven) movedToBreakEven.add(setup);
          if (result == null) continue;
          setup.outcome = result.outcome;
          setup.closedPrice = double.parse(result.exitPrice.toStringAsFixed(2));
          setup.closedAt = _now().toUtc();
          closed.add(setup);
        }
        return closed.isNotEmpty || movedToBreakEven.isNotEmpty;
      });
    } catch (e) {
      _log('Trade Outcome Watcher: sweep failed: $e');
      return false;
    }
    for (final setup in movedToBreakEven) {
      _log('⚖️ Break-Even — ${setup.setupLabel} reached 1:1 R:R, Stop Loss moved to Entry '
          '\$${setup.effectiveEntry.toStringAsFixed(2)} (Take Profit stays at '
          '\$${setup.takeProfit.toStringAsFixed(2)})');
    }

    // Break-Even — Broker Sync (2026-09-20, revised 2026-09-21 — "بدون قفل
    // جزئي، بس تحريك الستوب للدخول عند 1R"): mirrors the local Break-Even
    // flip onto the REAL MT5 position by moving its live Stop Loss to
    // Entry — the FULL lot keeps running from there to either Break-Even
    // (0) or the original Take Profit, a clean binary outcome. No partial
    // close is sent (Automatic Partial Take-Profit was removed the same
    // day — see AppConfig's note next to the retired partialTakeProfit
    // Fraction getter). Only applies to a setup this app itself
    // auto-opened ([brokerTicket] set — see [check]'s Auto-Trading block);
    // a signal-only (or manually-opened) trade has nothing to sync
    // against. Gated on [breakEvenSynced] so it is only ever attempted
    // once per trade, regardless of how many sweep cycles see
    // [breakEvenActive] stay true afterwards.
    final toSyncWithBroker = movedToBreakEven.where((s) => s.brokerTicket != null && !s.breakEvenSynced).toList();
    if (toSyncWithBroker.isNotEmpty) {
      for (final setup in toSyncWithBroker) {
        final ticket = setup.brokerTicket!;
        // effectiveEntry, not entry: moves the REAL SL to the broker's
        // own fill price (see TradeSetup.actualFillPrice) — using the
        // theoretical signal price here is exactly the bug that motivated
        // this field (2026-09-21).
        final slOk = await _trading.modifyStopLoss(ticket: ticket, sl: setup.effectiveEntry);
        _log(slOk
            ? '🏦 Broker Sync — Ticket #$ticket: live Stop Loss moved to Entry \$${setup.effectiveEntry.toStringAsFixed(2)} '
                '(Break-Even)'
            : '⚠️ Broker Sync — SL move to Break-Even failed for Ticket #$ticket — check the position manually in MT5');
      }
      try {
        await HistoryStore.mutate((history) {
          var changed = false;
          for (final setup in history) {
            if (toSyncWithBroker.any((s) => s.uid == setup.uid)) {
              setup.breakEvenSynced = true;
              changed = true;
            }
          }
          return changed;
        });
      } catch (e) {
        _log('Broker Sync: failed to persist breakEvenSynced flag: $e');
      }
    }

    for (final setup in closed) {
      _log(setup.outcome == TradeOutcome.win
          ? '🎯 TP Hit — ${setup.setupLabel} closed WIN @ \$${setup.closedPrice!.toStringAsFixed(2)} (${setup.pips! >= 0 ? "+" : ""}${setup.pips!.toStringAsFixed(1)} pips)'
          : '🛑 SL Hit — ${setup.setupLabel} closed LOSS @ \$${setup.closedPrice!.toStringAsFixed(2)} (${setup.pips!.toStringAsFixed(1)} pips)');
      await _notifier.sendOutcome(setup);
    }
    return closed.isNotEmpty;
  }

  /// Candle sweep (every cycle): walks every 15M candle — including the
  /// still-forming one — that opened after each trade's entry, so a wick
  /// through SL/TP is caught intrabar, cycles that were skipped (app killed,
  /// Doze) don't lose the candles in between, and a wick from BEFORE the
  /// trade existed can never close it.
  Future<bool> _resolveOpenTrades(List<Candle> m15Raw) => _sweepOpenTrades((setup) => _brokerOwns(setup)
      ? null
      : setup.evaluateOutcomeOverCandles(m15Raw, updateBreakEven: AppConfig.breakEvenEnabled));

  /// With reconciliation on, a trade backed by a REAL position is closed by
  /// the broker's record (see BrokerReconciler), not by this price estimate.
  bool _brokerOwns(TradeSetup setup) => setup.brokerTicket != null && AppConfig.reconcileWithBroker;

  /// Reconciles the trade log with MT5 and sends the usual outcome
  /// notification for every trade the broker closed.
  Future<ReconcileResult> reconcile() async {
    final result = await _reconciler.reconcile();
    for (final setup in result.newlyClosed) {
      await _notifier.sendOutcome(setup);
    }
    return result;
  }

  /// Sub-second fast path — called by MonitorEngine on every bridge tick. A
  /// BUY closes on the bid, a SELL on the ask.
  Future<bool> resolveOpenTradesAtTick({required double bid, required double ask}) =>
      _sweepOpenTrades((setup) => _brokerOwns(setup)
          ? null
          : setup.evaluateOutcomeAtTick(bid: bid, ask: ask, updateBreakEven: AppConfig.breakEvenEnabled));

  /// Manual Close (2026-09-17, explicit request): closes the OPEN trade
  /// identified by [tradeId] (TradeSetup.uid) at [currentPrice] — pips are
  /// computed the normal way (relative to Entry) and the outcome is
  /// persisted as [TradeOutcome.manualClose] rather than win/loss. Returns
  /// true if a matching open trade was found and closed, false otherwise
  /// (already closed / unknown id).
  Future<ManualCloseResult> closeTradeManually(String tradeId, double currentPrice) async {
    final open = (await HistoryStore.load())
        .where((s) => s.uid == tradeId && s.outcome == TradeOutcome.open && !s.isMissed)
        .toList();
    if (open.isEmpty) {
      _log('Manual Close requested for unknown/already-closed trade id: $tradeId');
      return const ManualCloseResult(closed: false, message: 'This trade is already closed.');
    }

    // A trade backed by a REAL MT5 position must be closed there first:
    // marking it closed locally while the position stays open would leave
    // real exposure that the app no longer tracks or protects.
    var price = currentPrice;
    var brokerClosed = false;
    var note = '';
    final ticket = open.first.brokerTicket;
    if (ticket != null) {
      final outcome = await _trading.closePosition(ticket);
      if (outcome.success) {
        brokerClosed = true;
        price = outcome.price ?? currentPrice;
      } else if (outcome.notFound) {
        _log('Manual Close: MT5 position #$ticket no longer exists — recording the close locally');
        note = ' (the MT5 position was already closed)';
      } else {
        _log('Manual Close FAILED for MT5 position #$ticket: ${outcome.error}');
        return ManualCloseResult(
          closed: false,
          message: 'Could not close the MT5 position #$ticket: ${outcome.error}. '
              'The trade is still open — try again or close it in MetaTrader.',
        );
      }
    }

    TradeSetup? closedSetup;
    await HistoryStore.mutate((history) {
      for (final setup in history) {
        if (setup.uid != tradeId) continue;
        if (setup.closeTradeManually(price)) closedSetup = setup;
        break;
      }
      return closedSetup != null;
    });
    if (closedSetup == null) {
      // The sweep closed it locally between the load above and now.
      _log('Manual Close: trade $tradeId was already closed by the outcome sweep');
      return ManualCloseResult(
        closed: brokerClosed,
        brokerClosed: brokerClosed,
        message: brokerClosed ? 'Closed on MT5.' : 'This trade is already closed.',
      );
    }
    final setup = closedSetup!;
    _log('✋ Manually Closed — ${setup.setupLabel} closed @ \$${setup.closedPrice!.toStringAsFixed(2)} '
        '(${setup.pips! >= 0 ? "+" : ""}${setup.pips!.toStringAsFixed(1)} pips)');
    await _notifier.sendOutcome(setup);
    return ManualCloseResult(
      closed: true,
      brokerClosed: brokerClosed,
      message: 'Closed at \$${price.toStringAsFixed(2)}'
          '${brokerClosed ? ' — the MT5 position was closed' : (ticket == null ? ' (signal only, no MT5 position)' : '')}$note.',
    );
  }

  bool _cacheValid(int timeframeMinutes, _CachedCandles cached, DateTime now) {
    final ttl = _cacheTtl[timeframeMinutes] ?? Duration.zero;
    if (ttl <= Duration.zero || now.difference(cached.fetchedAt) >= ttl) return false;
    final tfMs = timeframeMinutes * 60000;
    final fetchedBucket = cached.fetchedAt.toUtc().millisecondsSinceEpoch ~/ tfMs;
    final nowBucket = now.toUtc().millisecondsSinceEpoch ~/ tfMs;
    return fetchedBucket == nowBucket;
  }

  Future<_CandleFetch> _getCandles(DataService dataService, int timeframeMinutes, int count) async {
    final now = _now();
    final cached = _candleCache[timeframeMinutes];
    if (cached != null && _cacheValid(timeframeMinutes, cached, now)) {
      return (candles: cached.candles, isFresh: true, source: cached.source);
    }

    try {
      final fresh = await dataService.getCandles(timeframeMinutes: timeframeMinutes, count: count);
      final source = AppConfig.useMockData ? null : ConnectionStatusService.instance.current;
      if (fresh.isNotEmpty) {
        _candleCache[timeframeMinutes] = _CachedCandles(_now(), fresh, source);
        return (candles: fresh, isFresh: true, source: source);
      }
    } catch (e) {
      if (cached == null) rethrow;
      _log('Candle refresh failed for ${timeframeMinutes}m — serving cached data: $e');
    }

    // Stale-While-Revalidate: serve the last good copy without bumping
    // fetchedAt, so the next cycle tries to refresh again.
    if (cached != null) {
      return (candles: cached.candles, isFresh: false, source: cached.source);
    }
    return (candles: const <Candle>[], isFresh: false, source: null);
  }

  /// AI commentary + local/Telegram notification for a setup that survived
  /// conflict resolution AND de-duplication (see MonitorEngine).
  Future<void> finalizeSetup(TradeSetup setup) async {
    setup.aiReason = await _ai.explainSetup(setup);
    await _notifier.sendSignal(setup);
  }

  Future<SignalCheckResult> check() async {
    // Built fresh each cycle; the candle DATA itself is cached above.
    final dataService = _newDataService();
    final notes = <String>[];
    _log('--- scan cycle start ---');

    // Strategy config (bridge-owned): fetch, then promote exactly once so
    // this whole scan sees ONE consistent configuration.
    await StrategyConfig.instance.refresh();
    final cfg = StrategyConfig.instance.beginCycle();
    _syncEngineStates();

    // Economic Calendar — 15-Minute Advance Notification.
    try {
      final dueNews = await _newsCalendar.dueForAdvanceNotice();
      for (final event in dueNews) {
        await _notifier.sendNewsAlert(event);
      }
    } catch (e) {
      _log('News calendar check failed: $e');
    }

    // Fetch all three timeframes. The forming candle is kept in the *Raw
    // lists (live price, outcome sweep) and stripped for every strategy.
    final h4Fetch = await _getCandles(dataService, AppConfig.tfH4, 150);
    final h1Fetch = await _getCandles(dataService, AppConfig.tfH1, 300);
    final m15Fetch = await _getCandles(dataService, AppConfig.tfM15, 300);
    // 5M is ONLY ever fetched for the ORB and Breakout/Momentum tiers
    // (2026-09-18) — every other strategy was deliberately moved off
    // 1M/5M candles entirely on 2026-09-14 ("completely disable Scalping
    // strategies"). Shared between the two (one fetch, not two) and gated
    // on either being enabled, so a user who enables neither sees zero
    // change in request volume against the TwelveData/Yahoo quota that
    // decision was protecting. 200 candles at 5M is ~16.6 hours —
    // comfortably covers a session's Opening Range plus the rest of that
    // day's trading, and far more than ATR(14) needs for Breakout/Momentum.
    final needsM5 = AppConfig.useOrb || AppConfig.useBreakoutMomentum;
    final bridgeLive = !AppConfig.useMockData && !AppConfig.disableMt5Bridge;
    // The Fast-Impulse Guard (2026-10-07) also reads 5M, but only as an OPTIONAL extra: it is fetched for
    // it only when Range Bounce — the engine it restricts — is on, the guard is not off and the MT5 bridge
    // is the feed (a local call, not a metered one; IMPULSE_FORCE_M5 overrides that for backtests), and a
    // failed fetch just leaves the guard on 15M.
    final impulseWantsM5 = !needsM5 &&
        (bridgeLive || (AppConfig.impulseForceM5 && !AppConfig.useMockData)) &&
        AppConfig.enableRangingBounceMode &&
        AppConfig.impulseGuardMode != GuardMode.off;
    _CandleFetch? m5Fetch;
    if (needsM5) {
      m5Fetch = await _getCandles(dataService, AppConfig.tfM5, 200);
    } else if (impulseWantsM5) {
      try {
        m5Fetch = await _getCandles(dataService, AppConfig.tfM5, 200);
      } catch (e) {
        _log('Fast-Impulse Guard: 5M candles unavailable ($e) — using 15M only this scan');
      }
    }

    final nowUtc = _now().toUtc();
    final h4 = closedCandlesOnly(h4Fetch.candles, AppConfig.tfH4, nowUtc);
    final h1 = closedCandlesOnly(h1Fetch.candles, AppConfig.tfH1, nowUtc);
    final m15Raw = m15Fetch.candles;
    final m15 = closedCandlesOnly(m15Raw, AppConfig.tfM15, nowUtc);
    final m5 = m5Fetch == null ? const <Candle>[] : closedCandlesOnly(m5Fetch.candles, AppConfig.tfM5, nowUtc);
    final feed = m15Fetch.source;
    final feedLabel = feed?.label ?? 'Mock data';

    final bias = _fourHourBias(h4);
    final hourlyBias = _hourlyBias(h1);

    // Strict 1H+4H SWING-STRUCTURE consensus (2026-09-18) — distinct from
    // the [bias]/[hourlyBias] pair above, which read net price movement
    // over the last ~20 candles. The HTF Retest Protocol is defined as a
    // with-trend continuation off market structure, so it gates on this
    // (higher-highs/higher-lows agreement between both timeframes) and is
    // skipped entirely while structure is choppy or the two disagree.
    final structureBias4h = _ict.structureBias(h4);
    final htfStructureBias =
        (structureBias4h != null && structureBias4h == _ict.structureBias(h1)) ? structureBias4h : null;

    if (h1.isEmpty || m15.isEmpty) {
      notes.add('HTF structure: 1H=${h1.length} 15M=${m15.length} closed candles | Syncing market data...');
      _log('Syncing market data — 1H=${h1.length} 15M=${m15.length} closed candles, not ready yet');
      return SignalCheckResult(
        status: 'No new signal — ${notes.join(" | ")} (4H context: ${h4.length} candles, bias: ${_biasLabel(bias)})',
        feed: feed,
      );
    }

    // Live price: the forming candle's latest close when present.
    final livePrice = m15Raw.last.close;

    // Market Closed / Stale Data Feed Guard — measured from when the newest
    // candle (forming or closed) was last able to update, in real UTC.
    final newest = m15Raw.last;
    final newestEnd = newest.time.toUtc().add(const Duration(minutes: AppConfig.tfM15));
    final lastUpdate = newestEnd.isAfter(nowUtc) ? nowUtc : newestEnd;
    final feedAge = nowUtc.difference(lastUpdate);
    const maxFeedAge = Duration(minutes: AppConfig.tfM15 * AppConfig.staleFeedTimeframeMultiplier);
    if (feedAge > maxFeedAge) {
      _log('Market Closed / Stale Data Feed detected '
          '(Current: ${nowUtc.toIso8601String()}, newest candle: ${newest.time.toIso8601String()}). '
          'Skipping signal generation.');
      return SignalCheckResult(
        status: 'Market Closed — $feedLabel newest candle ${feedAge.inMinutes}m old '
            '(4H context: ${h4.length} candles, bias: ${_biasLabel(bias)})',
        feed: feed,
        livePrice: livePrice,
      );
    }

    // Futures-feed guard (see AppConfig.allowFuturesFallbackSignals).
    if (feed == FeedSource.fallbackYahoo && !AppConfig.allowFuturesFallbackSignals) {
      _log('Only Yahoo GC=F (futures) is reachable — pausing signals and outcome tracking, '
          'its prices differ from spot XAUUSD');
      return SignalCheckResult(
        status: 'Paused — only Yahoo GC=F futures feed reachable (prices differ from spot). '
            'Start the MT5 bridge or check TwelveData.',
        feed: feed,
        livePrice: livePrice,
      );
    }

    // Price alerts against the live price.
    try {
      final fired = await _alerts.checkAndTrigger(livePrice);
      for (final alert in fired) {
        await _notifier.sendPriceAlert(alert, livePrice);
      }
    } catch (e) {
      _log('Price alert check failed: $e');
    }

    // Trade Outcome Watcher.
    await _resolveOpenTrades(m15Raw);

    // Broker truth for real positions: closes, corrected fills, orphans.
    final reconciled = await reconcile();
    if (reconciled.changedAnything) _log('🔄 Reconcile: ${reconciled.summary}');
    if (reconciled.hasWarnings) notes.add('Reconcile: ${reconciled.summary}');

    // Trade approval: learn what became of proposals waiting on the owner. Runs
    // BEFORE anything can return early, so an approved trade is imported even
    // while trading is paused, and BEFORE the next reconcile could mistake its
    // position for an unknown one.
    final approvals = await _approval.sync();
    for (final trade in approvals.executed) {
      _pendingPreState.remove(trade.uid);
      _log('✅ Approved trade is live on MT5 — ${trade.setupLabel} #${trade.brokerTicket} '
          '@ \$${trade.effectiveEntry.toStringAsFixed(2)} ${trade.lotSize ?? ""} lots');
      await _notifier.sendSignal(trade, telegram: false);
    }
    for (final released in approvals.released) {
      _releaseApproval(released, cfg);
    }

    // Account-level daily loss lock (enforced by the bridge, which also refuses
    // the orders): no point generating signals that cannot be traded today.
    final risk = await _trading.getRiskStatus();
    if (risk != null && risk.locked) {
      final lost = risk.lockedLossPercent ?? risk.lossPercent;
      notes.add('$feedLabel | Daily loss limit reached'
          '${lost == null ? "" : " (-${lost.toStringAsFixed(2)}% of ${risk.limitPercent.toStringAsFixed(1)}%)"}'
          ' — no new signals until 00:00 UTC');
      _log('Daily loss lock active — skipping signal generation this cycle');
      return SignalCheckResult(
        status: 'No new signal — ${notes.join(" | ")} (4H context: ${h4.length} candles, bias: ${_biasLabel(bias)})',
        feed: feed,
        livePrice: livePrice,
      );
    }

    // Bridge-wide pause (/pause, mode.paused): open trades keep being tracked
    // above, but nothing new is generated — no phantom signals either.
    if (cfg.paused) {
      notes.add('$feedLabel | Paused by the bridge config (mode.paused) — no new signals');
      _log('Paused by the bridge config — skipping signal generation this cycle');
      return SignalCheckResult(
        status: 'No new signal — ${notes.join(" | ")} (4H context: ${h4.length} candles, bias: ${_biasLabel(bias)})',
        feed: feed,
        livePrice: livePrice,
      );
    }

    // One Active Trade Limit (2026-09-17, explicit request): while any
    // trade is still open, no new signal is generated at all — strategy
    // evaluation is skipped entirely until the current trade closes
    // (win, loss, or manual close).
    final history = await HistoryStore.load();
    // A signal nobody traded (expired / rejected approval) is tracked for the record but is not a trade: it must
    // never hold back the next signal.
    final openTrades = history.where((s) => s.outcome == TradeOutcome.open && !s.isMissed).toList();
    if (AppConfig.oneActiveTradeLimit && openTrades.isNotEmpty) {
      final open = openTrades.first;
      notes.add('$feedLabel | One Active Trade Limit: ${open.setupLabel} @ ${open.entry} still open — '
          'new signal generation paused until it closes');
      _log(
          'One Active Trade Limit: ${open.setupLabel} @ ${open.entry} still open — skipping signal generation this cycle');
      return SignalCheckResult(
        status: 'No new signal — ${notes.join(" | ")} (4H context: ${h4.length} candles, bias: ${_biasLabel(bias)})',
        feed: feed,
        livePrice: livePrice,
      );
    }

    final waiting = await PendingStore.load();
    if (waiting.isNotEmpty) {
      final p = waiting.first;
      final until = p.expiresAt.toLocal();
      final hh = until.hour.toString().padLeft(2, '0');
      final mm = until.minute.toString().padLeft(2, '0');
      final ss = until.second.toString().padLeft(2, '0');
      notes.add('$feedLabel | Awaiting your Telegram approval: ${p.setup.setupLabel} @ ${p.setup.entry} '
          '(decide before $hh:$mm:$ss)');
      return SignalCheckResult(
        status: 'No new signal — ${notes.join(" | ")} (4H context: ${h4.length} candles, bias: ${_biasLabel(bias)})',
        feed: feed,
        livePrice: livePrice,
      );
    }

    final lossStreak = _todayLossStreak(history, nowUtc);
    if (AppConfig.dailyLossStreakLimit > 0 && lossStreak >= AppConfig.dailyLossStreakLimit) {
      notes.add('$feedLabel | Daily Loss Circuit Breaker: $lossStreak consecutive losses today — '
          'new signal generation paused until 00:00 UTC');
      _log('Daily Loss Circuit Breaker: $lossStreak consecutive losses today — skipping signal generation this cycle');
      return SignalCheckResult(
        status: 'No new signal — ${notes.join(" | ")} (4H context: ${h4.length} candles, bias: ${_biasLabel(bias)})',
        feed: feed,
        livePrice: livePrice,
      );
    }

    // Market-dynamics safety layers (2026-10-07). The Chaos Filter is the one cross-engine layer: in BLOCK
    // mode a stressed market pauses every engine for this scan, before any of them can burn a debounce; in
    // SHADOW mode the scan goes on and whatever fires is tagged with what the filter would have done.
    final regime = await _assessRegime(
      dataService: dataService,
      m15: m15,
      m15Raw: m15Raw,
      m5: m5,
      nowUtc: nowUtc,
      bridgeLive: bridgeLive,
    );
    if (regime.chaosActive) {
      final why = regime.chaos.reason;
      if (regime.chaosMode == GuardMode.block) {
        notes.add('$feedLabel | Chaos filter: $why — all engines paused');
        _logGuardOnce('chaos-block|${regime.chaos.episodeKey}', '⏸ Chaos filter PAUSE — all engines: $why');
        return SignalCheckResult(
          status: 'No new signal — ${notes.join(" | ")} (4H context: ${h4.length} candles, bias: ${_biasLabel(bias)})',
          feed: feed,
          livePrice: livePrice,
        );
      }
      _logGuardOnce('chaos-shadow|${regime.chaos.episodeKey}', '🕶️ [SHADOW] Chaos filter would have paused all engines: $why');
    }

    // High-impact news blackout for EVERY engine (2026-10-09, explicit request). The bridge's `filters.news` switch
    // existed but was never read here, so only the (disabled) Breakout tier ever honoured it. Now no engine opens a
    // trade while a high-impact USD release is within [AppConfig.newsBlackoutMinutes] either side of now; positions
    // already open are untouched. The calendar being unavailable never blocks (see NewsCalendarService).
    if (AppConfig.newsFilterEnabled && AppConfig.newsBlackoutMinutes > 0) {
      final window = AppConfig.newsBlackoutMinutes;
      final event = await _newsCalendar.blackoutEvent(Duration(minutes: window), now: nowUtc);
      if (event != null) {
        final at = formatUtcHm(event.timeUtc);
        notes.add('$feedLabel | News blackout: ${event.name} at $at UTC (high-impact USD) — no new entries '
            'within $window min of the release');
        _logGuardOnce('news|${event.name}@${event.timeUtc.toIso8601String()}',
            '📰 News blackout — ${event.name} at $at UTC: no engine opens a trade within $window min of it');
        return SignalCheckResult(
          status: 'No new signal — ${notes.join(" | ")} (4H context: ${h4.length} candles, bias: ${_biasLabel(bias)})',
          feed: feed,
          livePrice: livePrice,
        );
      }
    }

    final htfZones = _ta.buildHtfZones(candles15m: m15, candles1h: h1, candles4h: h4);
    final htfNote = 'HTF structure: 4H=${h4.length} 1H=${h1.length}${h1Fetch.isFresh ? "" : "(cached)"} '
        '15M=${m15.length}${m15Fetch.isFresh ? "" : "(cached)"} closed candles | ${htfZones.length} Key Zones';
    final baseInfo = '[$feedLabel] $htfNote';

    // Three of the four strategy tiers all trade off 15M/1H/4H HTF Key
    // Zones and simply have nothing to evaluate without any — but ORB
    // (below) never reads a zone at all, so an empty zone pool must NOT
    // skip it too; the final `setups.isEmpty` check further down is what
    // actually decides whether this cycle produces "No new signal".
    final enginesOff = EngineIds.all.where((id) => !_engineEnabled(id)).toList();
    if (enginesOff.isNotEmpty) notes.add('Engines OFF: ${enginesOff.join(", ")}');
    final cooling = EngineIds.all.where(_cooling).toList();
    if (cooling.isNotEmpty) notes.add('Engines quiet after a decision: ${cooling.join(", ")}');
    final preFireState = {for (final id in EngineIds.all) id: _captureEngineState(id)};
    TradeSetup? legacySetup;
    TradeSetup? ictSetup;
    TradeSetup? iciSetup;
    if (htfZones.isEmpty) {
      notes.add('$baseInfo | No HTF Key Zones found on 15M/1H/4H yet');
      _log('No HTF zones found near current price \$${livePrice.toStringAsFixed(2)} — '
          '15M/1H/4H structure produced 0 Key Zones this cycle');
    } else {
      // Three of the four INDEPENDENT strategies (ORB is evaluated
      // separately below), each with its own debounce state.
      legacySetup = !_runnable(EngineIds.htfRetest, AppConfig.useHtfRetest)
          ? null
          : await _evaluateLegacyTrigger(
              m15: m15,
              htfZones: htfZones,
              bias: bias,
              hourlyBias: hourlyBias,
              htfStructureBias: htfStructureBias,
              baseInfo: baseInfo,
              notes: notes,
              livePrice: livePrice,
            );
      ictSetup = !_runnable(EngineIds.ict, AppConfig.useIct)
          ? null
          : await _evaluateIctTrigger(
              m15: m15,
              h1: h1,
              h4: h4,
              htfZones: htfZones,
              notes: notes,
              livePrice: livePrice,
            );
      iciSetup = !_runnable(EngineIds.ici, AppConfig.useIci)
          ? null
          : await _evaluateIciTrigger(
              m15: m15,
              h1: h1,
              h4: h4,
              htfZones: htfZones,
              notes: notes,
              livePrice: livePrice,
            );
    }

    // The Asia ORB tier (rebuilt 2026-10-09 as the fifth engine) — never reads htfZones, any candlestick pattern
    // or a trend gate; see orb_engine.dart. The 1H bias only colours its (informational) Confluence Score.
    final orbSetup = _runnable(EngineIds.orb, AppConfig.useOrb)
        ? await _evaluateOrbTrigger(
            candles5m: m5,
            bias1h: hourlyBias,
            nowUtc: nowUtc,
            notes: notes,
            livePrice: livePrice,
          )
        : null;

    // A FIFTH, fully independent strategy tier (2026-09-18, rebuilt
    // 2026-09-22): HTF zones are only ONE of its five level sources now
    // (Previous Day, session, swing and Opening Range levels don't need
    // them), so it still runs with an empty zone pool; see
    // breakout_momentum_engine.dart.
    final breakoutSetup = _runnable(EngineIds.breakout, AppConfig.useBreakoutMomentum)
        ? await _evaluateBreakoutTrigger(
            candles5m: m5,
            candles15m: m15,
            candlesH1: h1,
            htfZones: htfZones,
            nowUtc: nowUtc,
            notes: notes,
            livePrice: livePrice,
          )
        : null;

    // A SIXTH, fully independent strategy tier (2026-09-25) — the Ranging
    // Market Module. Unlike the five above it is deliberately the ONLY tier
    // that requires the ABSENCE of a clear HTF bias, so it complements them
    // rather than competing: it covers exactly the market state they are
    // built to stand down in. Needs htfZones, so it sits inside the same
    // guard the zone-reading tiers do.
    final zoneBounceSetup = _runnable(EngineIds.rangeBounce, AppConfig.enableRangingBounceMode) && htfZones.isNotEmpty
        ? await _evaluateZoneBounceTrigger(
            m15: m15,
            htfZones: htfZones,
            htfStructureBias: htfStructureBias,
            notes: notes,
            livePrice: livePrice,
            impulse: regime.impulse,
            impulseMode: regime.impulseMode,
          )
        : null;

    var setups = [
      if (legacySetup != null) legacySetup,
      if (ictSetup != null) ictSetup,
      if (iciSetup != null) iciSetup,
      if (orbSetup != null) orbSetup,
      if (breakoutSetup != null) breakoutSetup,
      if (zoneBounceSetup != null) zoneBounceSetup,
    ];

    // Engine Priority Resolution (2026-09-20, explicit request): replaces
    // the old score-only Cross-Strategy Conflict Guard, which only ever
    // intervened when the engines disagreed on DIRECTION. Now that a
    // surviving setup can open a REAL broker order (see Auto-Trading below),
    // at most one setup must ever leave this cycle regardless of whether the
    // engines that fired agree on direction or not — decided by the fixed
    // hierarchy, not the raw Confluence Score, so the same engine wins a
    // simultaneous race every time rather than whichever happened to score
    // higher that cycle.
    if (setups.length > 1) {
      final sorted = [...setups]..sort((a, b) => _enginePriorityRank(a).compareTo(_enginePriorityRank(b)));
      final kept = sorted.first;
      final dropped = sorted.skip(1).toList();
      final droppedLabel = dropped
          .map((s) => '${s.setupLabel} (${s.setupType.strategyFamily.label}, Score ${s.confluenceScore}/100)')
          .join(', ');
      _log('🏆 Engine Priority Resolution — ${setups.length} engines fired this cycle; keeping '
          '${kept.setupLabel} (${kept.setupType.strategyFamily.label}, highest priority) and dropping $droppedLabel');
      notes.add('🏆 Engine Priority Resolution: kept ${kept.setupLabel} (${kept.setupType.strategyFamily.label}) '
          '— dropped $droppedLabel');
      setups = [kept];
      // The dropped engines already marked themselves as having signalled; they never did.
      for (final loser in dropped) {
        final id = EngineIds.forFamily(loser.setupType.strategyFamily);
        _restoreEngineState(id, preFireState[id]!);
      }
    }

    if (setups.isEmpty) {
      return SignalCheckResult(
        status: 'No new signal — ${notes.join(" | ")} (4H context: ${h4.length} candles, bias: ${_biasLabel(bias)})',
        feed: feed,
        livePrice: livePrice,
      );
    }

    for (final setup in setups) {
      setup.dataSource = feedLabel;
      setup.configRevision = cfg.isEmpty ? null : cfg.revision;
      // SHADOW: the Chaos Filter would have paused this scan (BLOCK returned above, so only shadow gets here).
      if (regime.chaosActive) setup.addShadowFlag('${ShadowLayer.chaos}: ${regime.chaos.reason}');
    }

    final liveTradingReady = !AppConfig.useMockData && !AppConfig.disableMt5Bridge;
    final winner = setups.single;
    final winnerId = EngineIds.forFamily(winner.setupType.strategyFamily);

    // Single Active Position Guard (2026-09-20, explicit request): a REAL
    // broker check, on top of (not instead of) the local "One Active Trade
    // Limit" already enforced earlier this cycle — that one only catches a
    // LOCALLY-tracked setup; this catches ANY open XAUUSD position (a prior
    // auto-trade, or one opened by hand in the terminal) the local history
    // might not know about at all. A bridge that can't be reached fails
    // OPEN here (the signal still reaches the user) — only actual order
    // EXECUTION below treats an unverifiable account state as unsafe.
    if (liveTradingReady) {
      final openPositions = await _trading.getOpenPositions();
      if (openPositions.isNotEmpty) {
        const message = 'Signal skipped: Active XAUUSD position already open.';
        _restoreEngineState(winnerId, preFireState[winnerId]!); // nothing was proposed
        _log(message);
        notes.add(message);
        return SignalCheckResult(
          status: 'No new signal — ${notes.join(" | ")} (4H context: ${h4.length} candles, bias: ${_biasLabel(bias)})',
          feed: feed,
          livePrice: livePrice,
        );
      }
    }

    // Live Spread Protection (2026-09-20, explicit request): fetched fresh
    // here — never cached — since a spread spike (news, low liquidity) can
    // appear and vanish within seconds.
    if (liveTradingReady) {
      final spreadPips = await _trading.getSpreadPips();
      final spreadCap =
          cfg.engineMaxSpreadPips(EngineIds.forFamily(winner.setupType.strategyFamily)) ?? AppConfig.maxSpreadPips;
      if (spreadPips != null && spreadPips > spreadCap) {
        final message = 'Signal rejected: Live spread (${spreadPips.toStringAsFixed(1)} pips) exceeds maximum '
            'allowed (${spreadCap.toStringAsFixed(0)} pips).';
        _restoreEngineState(winnerId, preFireState[winnerId]!); // nothing was proposed
        _log(message);
        notes.add(message);
        return SignalCheckResult(
          status: 'No new signal — ${notes.join(" | ")} (4H context: ${h4.length} candles, bias: ${_biasLabel(bias)})',
          feed: feed,
          livePrice: livePrice,
        );
      }
    }

    // Dynamic Position Sizing + Auto-Trading Execution (2026-09-20, explicit
    // request) — entirely gated on AppConfig.enableAutoTrading (off by
    // default): with it off, [winner] stays exactly what it always was, a
    // signal-only alert with no lot size and no broker order.
    if (AppConfig.enableAutoTrading && liveTradingReady) {
      final account = await _trading.getAccount();
      if (account == null || !account.tradeAllowed) {
        _log('Auto-Trading: account snapshot unavailable or trading not allowed on the broker side — '
            '${winner.setupLabel} stays a signal-only alert, no order sent.');
      } else {
        final lot = _risk.sizeLot(equity: account.equity, stopLossDollars: winner.riskDollars);
        winner.lotSize = lot;
        if (cfg.autoTradeMode == 'approval') {
          // Nothing is traded here. The bridge asks the owner on Telegram, then
          // re-checks price, lot and every limit at the moment of approval.
          final proposal = await _approval.submit(winner, winnerId);
          if (proposal.isPending) {
            _pendingPreState[winner.uid] = preFireState[winnerId]!;
            notes.add('📲 ${winner.setupLabel} @ ${winner.entry} sent to Telegram for approval');
            return SignalCheckResult(
              status:
                  'Awaiting approval — ${notes.join(" | ")} (4H context: ${h4.length} candles, bias: ${_biasLabel(bias)})',
              feed: feed,
              livePrice: livePrice,
            );
          }
          _restoreEngineState(winnerId, preFireState[winnerId]!);
          _coolEngine(winnerId, const Duration(minutes: 2));
          final why = proposal.reason == null ? proposal.state : '${proposal.state}: ${proposal.reason}';
          _log('📲 ${winner.setupLabel} was not proposed for approval ($why)');
          notes.add('Signal not proposed for approval ($why)');
          return SignalCheckResult(
            status:
                'No new signal — ${notes.join(" | ")} (4H context: ${h4.length} candles, bias: ${_biasLabel(bias)})',
            feed: feed,
            livePrice: livePrice,
          );
        }
        final order = await _trading.openMarketOrder(
          direction: winner.direction,
          volume: lot,
          stopLoss: winner.stopLoss,
          takeProfit: winner.takeProfit,
          // The bridge re-checks that price has not run away from this entry, and sizes the lot itself in
          // the account's own currency ([lot] above is only an estimate that ignores the currency).
          entry: winner.entry,
          bridgeSizing: true,
        );
        if (order.success) {
          winner.brokerTicket = order.ticket;
          winner.lotSize = order.volume ?? lot;
          // The REAL fill price (2026-09-21, explicit fix): a market order
          // can slip a little from the theoretical [entry] priced off the
          // confirmation candle's close — every later money calculation
          // must use this, not entry, so Break-Even/live P&L exactly match
          // what the broker actually did (see TradeSetup.effectiveEntry).
          winner.actualFillPrice = order.price;
          _log('🏦 Auto-Trading — ${winner.directionLabel} order #${order.ticket} opened @ '
              '\$${order.price?.toStringAsFixed(2)} for ${order.volume ?? lot} lots ('
              '${cfg.lotMode == 'fixed' ? 'fixed lot' : 'Risk ${AppConfig.riskPercentPerTrade.toStringAsFixed(1)}% of \$${account.equity.toStringAsFixed(2)} equity'})');
        } else {
          _log('⚠️ Auto-Trading — broker rejected the ${winner.directionLabel} order: ${order.error}. '
              '${winner.setupLabel} still recorded as a signal-only alert.');
        }
      }
    }

    final summary = setups.map((s) => '${s.setupLabel} @ ${s.entry} (Score ${s.confluenceScore}/100)').join(' | ');
    return SignalCheckResult(
      status: '${setups.length} new signal${setups.length > 1 ? "s" : ""}: $summary',
      setups: setups,
      feed: feed,
      livePrice: livePrice,
    );
  }

  /// The original Strict Top-Down Dual-Mode strategy's trigger search +
  /// full Rule 1-4 gating chain, extracted unchanged from [check] (2026-
  /// 09-12) so it can run alongside the new ICT tier below rather than
  /// returning out of the whole cycle on its own. Every rejection reason
  /// is appended to the SHARED [notes] list (passed by reference) so the
  /// combined "No new signal" status still reads exactly as before when
  /// this is the only tier active. Returns null on any rejection, or the
  /// fired [TradeSetup] once every rule has passed.
  Future<TradeSetup?> _evaluateLegacyTrigger({
    required List<Candle> m15,
    required List<HtfZone> htfZones,
    required TradeDirection? bias,
    required TradeDirection? hourlyBias,
    required TradeDirection? htfStructureBias,
    required String baseInfo,
    required List<String> notes,
    required double livePrice,
  }) async {
    // 15M is the ONLY execution timeframe (2026-09-14, "completely disable
    // Scalping strategies" — 5M was previously primary with a 1M scalping
    // fallback; both are gone). The HTF Retest Protocol
    // (TaEngine.findExecutionTrigger) is the only path now — the standalone
    // Momentum/Breakout fallback and 15M Higher Low / Lower High Absorption
    // (SetupType.absorption15m) were both retired 2026-09-18, explicit
    // request: TaEngine.find15mAbsorptionTrigger is gone, along with the
    // strategy-specific 15M Structure Bias Gate this method used to apply
    // only to it.
    final ExecutionTrigger? trigger =
        _ta.findExecutionTrigger(candles: m15, htfZones: htfZones, htfBias: htfStructureBias);
    final triggerCandles = m15;
    const triggerTimeframeLabel = '15M';

    if (trigger == null) {
      notes.add('$baseInfo | Price not at a Key Zone, or no 15M trigger yet');
      _logNoTrigger(m15.last.close, htfZones);
      return null;
    }

    final triggerInfo =
        '$triggerTimeframeLabel ${trigger.type.label} @ ${trigger.zone.source} (\$${trigger.zone.price.toStringAsFixed(2)})';

    // Debounce: don't fire twice for the same trigger-timeframe candle close.
    final candleTime = triggerCandles.last.time;
    if (_lastSignalCandleTime == candleTime) {
      notes.add('$baseInfo | $triggerInfo | already signaled this candle');
      return null;
    }

    // Per-HTF-Zone Cooldown: same zone, still within the debounce window —
    // suppress regardless of direction, since this is the SAME setup, not a
    // new one. A different zone (or this zone at a rebuilt price) is a
    // different key and is never blocked here.
    final zoneKey = '${trigger.zone.source}@${trigger.zone.price.toStringAsFixed(2)}';
    final lastZoneFire = _lastZoneSignalTime[zoneKey];
    if (lastZoneFire != null && _now().difference(lastZoneFire) < AppConfig.directionalDebounceWindow) {
      final elapsedMin = _now().difference(lastZoneFire).inMinutes;
      notes.add(
        '$baseInfo | $triggerInfo | suppressed — zone already signaled ${elapsedMin}m ago '
        '(${AppConfig.directionalDebounceWindow.inMinutes}-min zone cooldown)',
      );
      _log('Setup rejected by Zone Cooldown — $zoneKey already signaled ${elapsedMin}m ago '
          '(${AppConfig.directionalDebounceWindow.inMinutes}-min cooldown)');
      return null;
    }

    final zone = SetupZone(
      type: trigger.type,
      zonePrice: trigger.zone.price,
      candleIndex: trigger.candleIndex,
      swingAnchor: trigger.swingAnchor,
      liquidityTarget: trigger.liquidityTarget,
    );
    final setup = _risk.buildTradeSetup(
      candles: triggerCandles,
      zone: zone,
      pattern: trigger.pattern,
      timeframeLabel: triggerTimeframeLabel,
      riskReward: AppConfig.rrFor(EngineIds.htfRetest),
    );
    if (setup == null) {
      notes.add('$baseInfo | $triggerInfo | Setup rejected: invalid risk distance (Entry == Stop Loss)');
      _log('Setup rejected by SL limit — invalid risk distance (Entry == Stop Loss), RiskEngine could not price it');
      return null;
    }

    if (_rejectsScalpingTimeframe(triggerTimeframeLabel)) {
      notes.add('$baseInfo | $triggerInfo | Scalping setup ignored (Timeframe < 15M)');
      return null;
    }

    if (_rejectsMinTakeProfitDistance(setup)) {
      notes.add(
          '$baseInfo | $triggerInfo | Setup rejected: TP distance below ${AppConfig.minTakeProfitPips.toStringAsFixed(0)} pips minimum');
      return null;
    }

    if (_rejectsMinStopLossDistance(setup)) {
      notes.add(
          '$baseInfo | $triggerInfo | Setup rejected: SL distance below ${AppConfig.minStopLossPips.toStringAsFixed(0)} pips minimum');
      return null;
    }

    if (_rejectsMaxStopLossDistance(setup)) {
      notes.add(
          '$baseInfo | $triggerInfo | Setup rejected: SL distance above ${AppConfig.maxStopLossPips.toStringAsFixed(0)} pips maximum');
      return null;
    }

    // Liquidity-Target R:R Floor (2026-09-18, HTF Retest Protocol) —
    // CURRENTLY INERT. It guarded the old behaviour where these setups
    // took Take Profit AT the next liquidity/HTF level rather than a fixed
    // multiple: a target landing close to Entry was real information (the
    // move has no room before price meets structure again), so the setup
    // was rejected rather than re-priced to a target nothing in the chart
    // supports. Since 2026-09-24 every tier prices TP at the fixed
    // AppConfig.riskRewardRatio (1.8), which is above
    // htfRetestMinRiskReward (1.5) by construction, so this can no longer
    // fire. Kept — not deleted — because it re-arms itself automatically
    // if RiskEngine's liquidityTarget pricing is ever restored, and
    // because it would start rejecting again on its own if the ratio were
    // ever configured below the floor.
    if (trigger.type == SetupType.htfRetest && setup.riskRewardRatio < AppConfig.htfRetestMinRiskReward) {
      notes.add('$baseInfo | $triggerInfo | Setup rejected: liquidity target only pays '
          '1:${setup.riskRewardRatio.toStringAsFixed(1)} '
          '(< 1:${AppConfig.htfRetestMinRiskReward} required)');
      _log('Setup rejected by Liquidity-Target R:R Floor — next liquidity at '
          '\$${setup.takeProfit.toStringAsFixed(2)} only pays 1:${setup.riskRewardRatio.toStringAsFixed(1)} '
          'against a \$${setup.riskDollars.toStringAsFixed(2)} stop');
      return null;
    }

    // HTF Trend Alignment Gate (2026-09-10, revised twice — checks BOTH 1H
    // and 4H bias, applies to EVERY setup): a setup opposing a CLEAR 1H OR
    // 4H macro bias is rejected outright, UNLESS it's anchored directly to
    // a larger-timeframe (1H) HTF zone (trigger.zone.source mentions "1H")
    // — direct contact with a bigger structural level is its own
    // justification regardless of the bias — EXCEPT for an HTF Retest
    // (SetupType.htfRetest), which never gets this exemption: the protocol
    // already requires the trade to agree with a strict 1H+4H swing-
    // structure consensus before it can fire at all (see
    // TaEngine._tryHtfRetestProtocol), so exempting it here would let a
    // setup that passed structure alignment slip past momentum alignment,
    // which is the very combination this gate exists to catch. (15M Higher
    // Low / Lower High Absorption used to be hard-gated the same way after
    // 3/3 countertrend BUYs fired through this exact loophole on
    // 2026-09-10 and all lost — that strategy tier was retired entirely
    // 2026-09-18, taking its own 15M Structure Bias Gate with it.)
    // Checking 1H too (not just 4H) catches a setup that agrees with the
    // slower 4H trend but is actually fighting the more immediate 1H move.
    // A neutral/unclear bias on either timeframe never blocks on its own —
    // only a CLEAR, opposing bias does.
    final isHtfRetest = trigger.type == SetupType.htfRetest;
    final isAtLargerTimeframeZone = !isHtfRetest && trigger.zone.source.contains('1H');
    final opposes4hBias = bias != null && setup.direction != bias;
    final opposes1hBias = hourlyBias != null && setup.direction != hourlyBias;
    if ((opposes4hBias || opposes1hBias) && !isAtLargerTimeframeZone) {
      notes.add(
        '$baseInfo | $triggerInfo | Setup rejected: opposes macro bias '
        '(1H: ${_biasLabel(hourlyBias)}, 4H: ${_biasLabel(bias)})',
      );
      _log('Setup rejected by HTF Trend Alignment — opposes macro bias '
          '(1H: ${_biasLabel(hourlyBias)}, 4H: ${_biasLabel(bias)}), '
          'and is not anchored to a larger-timeframe (1H) zone');
      return null;
    }

    // Trendline Clear-Path Gate (2026-09-10 — "بهذه المنطقة تحقق شروط
    // الربح والتيك بروفيت ولا يوجد دعم او مقاومة بتاثر على الصفقة"): a
    // Trendline-sourced trigger additionally requires that no OTHER HTF
    // zone sits between Entry and Take Profit in the trade's favor — a
    // competing S/R/trendline level in that path could cap the move
    // before TP is ever reached, so the trade is skipped entirely rather
    // than fired into an obstructed path. Only applies to trendline zones
    // (per the request's own wording); S/R-sourced triggers are unaffected.
    if (trigger.zone.source.contains('Trendline')) {
      HtfZone? blockingZone;
      for (final z in htfZones) {
        final between = setup.direction == TradeDirection.buy
            ? z.price > setup.entry && z.price < setup.takeProfit
            : z.price < setup.entry && z.price > setup.takeProfit;
        if (between) {
          blockingZone = z;
          break;
        }
      }
      if (blockingZone != null) {
        notes.add(
          '$baseInfo | $triggerInfo | Setup rejected: ${blockingZone.source} '
          '(\$${blockingZone.price.toStringAsFixed(2)}) blocks the path to TP',
        );
        _log('Setup rejected by Trendline Clear-Path — ${blockingZone.source} '
            '(\$${blockingZone.price.toStringAsFixed(2)}) sits between Entry and TP');
        return null;
      }
    }

    // Rule 2 — Signal Staleness Validation: Entry is the CLOSED confirmation
    // candle's close; [livePrice] is the forming candle's latest price.
    final drift = (livePrice - setup.entry).abs();
    if (_rejectsStaleDrift(setup, livePrice)) {
      notes.add(
        '$baseInfo | $triggerInfo | Setup rejected: Price drifted \$${drift.toStringAsFixed(2)} '
        '(> \$${AppConfig.maxStalePriceDriftDollars} max)',
      );
      return null;
    }

    // Rule 4 — High-Probability Confluence Filter. AppConfig.
    // minConfluenceScoreScalping (70) no longer applies to anything
    // (2026-09-14, Scalping strategies disabled) — every surviving setup
    // here is 15M+, so the standard floor is the only one that matters.
    final score = _confluenceScore(setup, bias);
    setup.confluenceScore = score;
    const requiredScore = AppConfig.minConfluenceScore;
    if (score < requiredScore) {
      notes.add(
        '$baseInfo | $triggerInfo | Confluence Score $score/100 — rejected '
        '(< $requiredScore required)',
      );
      _log('Setup score $score/100 is below minimum threshold $requiredScore/100 — rejected');
      return null;
    }

    // Rule 3 — Directional Debounce: suppress a direction flip within the
    // window, even across separate cycles.
    final withinWindow = _lastSignalDirection != null &&
        _lastSignalDirectionTime != null &&
        _now().difference(_lastSignalDirectionTime!) < AppConfig.directionalDebounceWindow;
    if (withinWindow && setup.direction != _lastSignalDirection) {
      notes.add(
        '$baseInfo | $triggerInfo | Score $score/100 | suppressed — opposes the last '
        '${_lastSignalDirection == TradeDirection.buy ? "BUY" : "SELL"} signal '
        '(${AppConfig.directionalDebounceWindow.inMinutes}-min debounce window)',
      );
      _log('Setup rejected by Directional Debounce — opposes the last '
          '${_lastSignalDirection == TradeDirection.buy ? "BUY" : "SELL"} signal within the '
          '${AppConfig.directionalDebounceWindow.inMinutes}-min window');
      return null;
    }

    if (!await _passesDxyFilter(setup, '$baseInfo | $triggerInfo', notes, EngineIds.htfRetest)) return null;

    // All rules passed — fire.
    _lastSignalCandleTime = candleTime;
    _lastSignalDirection = setup.direction;
    _lastSignalDirectionTime = _now();
    _lastZoneSignalTime[zoneKey] = _now();

    _log('✅ ${setup.directionLabel} Fired @ \$${setup.entry.toStringAsFixed(2)} '
        '(${setup.setupLabel}, Score $score/100, R:R 1:${setup.riskRewardRatio.toStringAsFixed(1)})');

    // AI commentary + notification are sent centrally by [check], AFTER the
    // Cross-Strategy Conflict Guard — never here — so a setup that ends up
    // dropped for opposing the other strategy's stronger setup this same
    // cycle never reaches the user at all.
    return setup;
  }

  /// The ICT/Smart-Money-Concepts strategy tier (see ict_engine.dart) —
  /// runs with its OWN debounce/candle-cooldown/zone-cooldown/directional-
  /// debounce state (the `_lastIct*` fields below), entirely separate from
  /// the legacy strategy's, so this can fire in the same cycle the legacy
  /// tier also fires (or already has an open trade) in, and vice versa.
  /// Reuses the SAME h1/h4/m15 candles and htfZones already fetched/
  /// built this cycle — no extra network requests. Returns null when
  /// IctEngine finds no trigger, or when it's rejected by the session
  /// filter, Premium/Discount (already applied inside IctEngine), score
  /// threshold, or either debounce.
  Future<TradeSetup?> _evaluateIctTrigger({
    required List<Candle> m15,
    required List<Candle> h1,
    required List<Candle> h4,
    required List<HtfZone> htfZones,
    required List<String> notes,
    required double livePrice,
  }) async {
    // Liquidity-Sweep Reversal realignment (2026-10-07): in BLOCK mode the engine itself skips a sweep
    // reversal that is neither with the 4H+1H bias nor a range-boundary grab, so the with-trend ICT paths
    // still get their turn on the same candle; in SHADOW mode it is judged after the fact (below).
    final sweepMode = AppConfig.ictSweepMode;
    final sweepParams = SweepAlignmentParams.current();
    final found = _ict.findTrigger(
      candles15m: m15,
      candles1h: h1,
      candles4h: h4,
      htfZones: htfZones,
      enforceSweepAlignment: sweepMode == GuardMode.block ? sweepParams : null,
      onSweepRejected: (rejected) {
        notes.add('[ICT] Liquidity-Sweep Reversal rejected: ${rejected.detail}');
        _logGuardOnce('ict-sweep|${m15.last.time.toUtc().toIso8601String()}|${rejected.kind.name}',
            '⛔ [ICT] Liquidity-Sweep Reversal rejected by the alignment rule: ${rejected.detail}');
      },
    );
    if (found == null) {
      notes.add('[ICT] No Order Block / FVG / Breaker / Liquidity Sweep / Trendline trigger this cycle');
      return null;
    }

    final trigger = found.trigger;
    final triggerCandles = found.candles;
    final triggerTimeframeLabel = found.timeframeLabel;
    final triggerInfo = '$triggerTimeframeLabel ${trigger.type.label} @ ${trigger.zone.source}';

    final candleTime = triggerCandles.last.time;
    if (_lastIctSignalCandleTime == candleTime) {
      notes.add('[ICT] $triggerInfo | already signaled this candle');
      return null;
    }

    final zoneKey = '${trigger.zone.source}@${trigger.zone.price.toStringAsFixed(2)}';
    final lastZoneFire = _lastIctZoneSignalTime[zoneKey];
    if (lastZoneFire != null && _now().difference(lastZoneFire) < AppConfig.directionalDebounceWindow) {
      notes.add('[ICT] $triggerInfo | suppressed — zone already signaled within the '
          '${AppConfig.directionalDebounceWindow.inMinutes}-min cooldown');
      return null;
    }

    final zone = SetupZone(type: trigger.type, zonePrice: trigger.zone.price, candleIndex: trigger.candleIndex);
    final setup = _risk.buildTradeSetup(
      candles: triggerCandles,
      zone: zone,
      pattern: trigger.pattern,
      timeframeLabel: triggerTimeframeLabel,
      riskReward: AppConfig.rrFor(EngineIds.ict),
    );
    if (setup == null) {
      notes.add('[ICT] $triggerInfo | rejected: invalid risk distance (Entry == Stop Loss)');
      return null;
    }

    if (_rejectsScalpingTimeframe(triggerTimeframeLabel)) {
      notes.add('[ICT] $triggerInfo | Scalping setup ignored (Timeframe < 15M)');
      return null;
    }

    if (_rejectsMinTakeProfitDistance(setup)) {
      notes.add(
          '[ICT] $triggerInfo | rejected: TP distance below ${AppConfig.minTakeProfitPips.toStringAsFixed(0)} pips minimum');
      return null;
    }

    if (_rejectsMinStopLossDistance(setup)) {
      notes.add(
          '[ICT] $triggerInfo | rejected: SL distance below ${AppConfig.minStopLossPips.toStringAsFixed(0)} pips minimum');
      return null;
    }

    if (_rejectsMaxStopLossDistance(setup)) {
      notes.add(
          '[ICT] $triggerInfo | rejected: SL distance above ${AppConfig.maxStopLossPips.toStringAsFixed(0)} pips maximum');
      return null;
    }

    // Session filter — Asian/London/New York are all accepted equally
    // (2026-09-12: "لو تحققت الشروط بالجلسة الاسيوية مافي مشكلة لدخول
    // صفقة"); only the low-liquidity gap outside all three needs the
    // score below to clear the override bar — "الا اذا كانت الاشارة قوية
    // جدا".
    final bias4h = _ict.structureBias(h4);
    final bias1h = _ict.structureBias(h1);
    final htfBias = (bias4h != null && bias4h == bias1h) ? bias4h : null;
    final score = _ictConfluenceScore(setup, htfBias, triggerCandles);
    setup.confluenceScore = score;

    final inSession = _ict.isHighLiquiditySession(_now().toUtc());
    if (!inSession && score < AppConfig.ictSessionOverrideScore) {
      notes.add('[ICT] $triggerInfo | rejected: outside Asian/London/New York session '
          '(Score $score/100 < ${AppConfig.ictSessionOverrideScore} override)');
      return null;
    }

    if (_rejectsStaleDrift(setup, livePrice)) {
      notes.add('[ICT] $triggerInfo | rejected: live price drifted too far from Entry');
      return null;
    }

    final requiredScore = trigger.type == SetupType.ictLiquiditySweepReversal
        ? AppConfig.minConfluenceScoreIctReversal
        : AppConfig.minConfluenceScore;
    if (score < requiredScore) {
      notes.add('[ICT] $triggerInfo | Confluence Score $score/100 — rejected (< $requiredScore required)');
      return null;
    }

    final withinWindow = _lastIctSignalDirection != null &&
        _lastIctSignalDirectionTime != null &&
        _now().difference(_lastIctSignalDirectionTime!) < AppConfig.directionalDebounceWindow;
    if (withinWindow && setup.direction != _lastIctSignalDirection) {
      notes.add('[ICT] $triggerInfo | Score $score/100 | suppressed — opposes the last ICT signal within the '
          '${AppConfig.directionalDebounceWindow.inMinutes}-min debounce window');
      return null;
    }

    if (!await _passesDxyFilter(setup, '[ICT] $triggerInfo', notes, EngineIds.ict)) return null;

    // SHADOW verdict of the sweep realignment: recorded only for a setup that really fires.
    if (sweepMode == GuardMode.shadow && trigger.type == SetupType.ictLiquiditySweepReversal) {
      final alignment = _ict.assessSweepAlignment(
        candles: triggerCandles,
        direction: setup.direction,
        htfBias: htfBias,
        params: sweepParams,
      );
      if (!alignment.allowed) {
        setup.addShadowFlag('${ShadowLayer.ictSweep}: ${alignment.detail}');
        _logGuardOnce('ict-sweep-shadow|${candleTime.toUtc().toIso8601String()}|${setup.direction.name}',
            '🕶️ [SHADOW] [ICT] Liquidity-Sweep Reversal would have been rejected by the alignment rule: ${alignment.detail}');
      }
    }

    _lastIctSignalCandleTime = candleTime;
    _lastIctSignalDirection = setup.direction;
    _lastIctSignalDirectionTime = _now();
    _lastIctZoneSignalTime[zoneKey] = _now();

    _log('✅ [ICT] ${setup.directionLabel} Fired @ \$${setup.entry.toStringAsFixed(2)} '
        '(${setup.setupLabel}, Score $score/100, R:R 1:${setup.riskRewardRatio.toStringAsFixed(1)})');

    // AI commentary + notification are sent centrally by [check], AFTER the
    // Cross-Strategy Conflict Guard — see the matching note in
    // [_evaluateLegacyTrigger].
    return setup;
  }

  /// ICT tier's own Confluence Score (0-100), mirroring [_confluenceScore]'s
  /// shape but swapping its last component for an Order Flow strength
  /// read (candle body-to-range ratio) per the spec's "دمج مبادئ الـOrder
  /// Flow مثل قوة الشموع... اذا دعم الـOrder Flow الصفقة تزداد قوتها". The
  /// Liquidity-Sweep Reversal path is exempt from the HTF-bias-alignment
  /// component (full credit regardless) since it's built to trade AGAINST
  /// the immediate structure by design — its own 3-condition gate already
  /// did that vetting before this is ever reached.
  int _ictConfluenceScore(TradeSetup setup, TradeDirection? htfBias, List<Candle> triggerCandles) {
    var score = 0;

    final isReversal = setup.setupType == SetupType.ictLiquiditySweepReversal;
    if (isReversal || htfBias == setup.direction) {
      score += 25;
    } else if (htfBias == null) {
      score += 10;
    }

    score += switch (setup.pattern) {
      CandlePattern.bullishEngulfing || CandlePattern.bearishEngulfing => 25,
      CandlePattern.bullishAbsorption || CandlePattern.bearishAbsorption => 25,
      CandlePattern.bullishMomentum || CandlePattern.bearishMomentum => 20,
      CandlePattern.bullishPinbar || CandlePattern.bearishPinbar => 15,
      CandlePattern.doji || CandlePattern.none => 0,
    };

    if (setup.riskRewardRatio >= AppConfig.rrFor(EngineIds.ict)) score += 25;

    final confirmation = triggerCandles.last;
    final bodyRatio = confirmation.range > 0 ? confirmation.bodySize / confirmation.range : 0.0;
    score += bodyRatio >= 0.5 ? 25 : 10;

    return score;
  }

  /// The Impulse-Correction-Impulse strategy tier (see impulse_correction_
  /// engine.dart) — runs with its OWN debounce/candle-cooldown/zone-
  /// cooldown/directional-debounce state (the `_lastIci*` fields), entirely
  /// separate from the legacy and ICT strategies', so this can fire in the
  /// same cycle either of them also fires (or already has an open trade)
  /// in. Reuses the SAME h1/h4/m15 candles and htfZones already
  /// fetched/built this cycle. Unlike ICT, NO path here is exempt from HTF
  /// alignment — a strict 1H+4H consensus is mandatory.
  Future<TradeSetup?> _evaluateIciTrigger({
    required List<Candle> m15,
    required List<Candle> h1,
    required List<Candle> h4,
    required List<HtfZone> htfZones,
    required List<String> notes,
    required double livePrice,
  }) async {
    final found = _ici.findTrigger(candles15m: m15, candles1h: h1, candles4h: h4, htfZones: htfZones);
    if (found == null) {
      notes.add('[ICI] No Impulse-Correction-Impulse trigger this cycle');
      return null;
    }

    final trigger = found.trigger;
    final triggerCandles = found.candles;
    final triggerTimeframeLabel = found.timeframeLabel;
    final triggerInfo = '$triggerTimeframeLabel ${trigger.type.label} @ ${trigger.zone.source}';

    final candleTime = triggerCandles.last.time;
    if (_lastIciSignalCandleTime == candleTime) {
      notes.add('[ICI] $triggerInfo | already signaled this candle');
      return null;
    }

    final zoneKey = '${trigger.zone.source}@${trigger.zone.price.toStringAsFixed(2)}';
    final lastZoneFire = _lastIciZoneSignalTime[zoneKey];
    if (lastZoneFire != null && _now().difference(lastZoneFire) < AppConfig.directionalDebounceWindow) {
      notes.add('[ICI] $triggerInfo | suppressed — zone already signaled within the '
          '${AppConfig.directionalDebounceWindow.inMinutes}-min cooldown');
      return null;
    }

    final zone = SetupZone(type: trigger.type, zonePrice: trigger.zone.price, candleIndex: trigger.candleIndex);
    var setup = _risk.buildTradeSetup(
      candles: triggerCandles,
      zone: zone,
      pattern: trigger.pattern,
      timeframeLabel: triggerTimeframeLabel,
      riskReward: AppConfig.rrFor(EngineIds.ici),
    );
    if (setup == null) {
      notes.add('[ICI] $triggerInfo | rejected: invalid risk distance (Entry == Stop Loss)');
      return null;
    }

    // Dynamic ATR-based Stop Loss (2026-09-24, explicit request — replaces
    // the fixed $1.50 ICI-only floor). The invalidation distance now scales
    // with how much the market is ACTUALLY moving instead of sitting at a
    // constant that is far too tight in a volatile session and needlessly
    // wide in a quiet one:
    //
    //   finalSlPips = max(structure, iciSlAtrMultiplier x ATR(14), 30 pips)
    //
    // Structure still wins whenever it is the widest of the three, so a
    // genuinely deep correction keeps its own organic stop — this only ever
    // WIDENS a stop, never tightens one. The 30-pip ($3.00) hard floor
    // exists for XAUUSD's spread: anything tighter is taken out by the
    // spread and ordinary noise rather than by the setup being wrong.
    // ATR is measured on the execution timeframe itself (15M, the same
    // candles the trigger was found on); if there isn't enough history to
    // compute it yet, that term simply drops out of the max().
    //
    // Take Profit is repriced off the final risk so the configured R:R
    // still holds, and RiskEngine.calculateLotSize picks the new distance
    // up automatically — it reads TradeSetup.riskDollars, which is derived
    // from entry/stopLoss — so position size scales DOWN as the stop
    // widens and the 1% risk cap stays exact.
    // TradeSetup's price fields are final, so a re-priced setup is a fresh
    // instance rather than a mutation.
    final atr = _ta.averageTrueRange(triggerCandles, period: 14);
    final structureSlPips = setup.riskDollars / TradeSetup.dollarsPerPip;
    final atrSlPips = atr == null ? 0.0 : (atr * AppConfig.iciSlAtrMultiplier) / TradeSetup.dollarsPerPip;
    final finalSlPips = _risk.iciStopLossPips(structureSlPips: structureSlPips, atr: atr);

    if (finalSlPips > structureSlPips) {
      final widenedRisk = finalSlPips * TradeSetup.dollarsPerPip;
      final newStopLoss = setup.direction == TradeDirection.buy ? setup.entry - widenedRisk : setup.entry + widenedRisk;
      final newTakeProfit = setup.direction == TradeDirection.buy
          ? setup.entry + AppConfig.rrFor(EngineIds.ici) * widenedRisk
          : setup.entry - AppConfig.rrFor(EngineIds.ici) * widenedRisk;
      _log('[ICI] SL widened ${structureSlPips.toStringAsFixed(1)} -> ${finalSlPips.toStringAsFixed(1)} pips '
          '(ATR(14) ${atr == null ? "n/a" : "\$${atr.toStringAsFixed(2)} -> ${atrSlPips.toStringAsFixed(1)}p"}, '
          'floor ${AppConfig.iciMinStopLossPips.toStringAsFixed(0)}p)');
      setup = TradeSetup(
        symbol: setup.symbol,
        direction: setup.direction,
        timeframeLabel: setup.timeframeLabel,
        setupType: setup.setupType,
        entry: setup.entry,
        stopLoss: double.parse(newStopLoss.toStringAsFixed(2)),
        takeProfit: double.parse(newTakeProfit.toStringAsFixed(2)),
        pattern: setup.pattern,
        detectedAt: setup.detectedAt,
        slWasClamped: true,
      );
    }

    if (_rejectsScalpingTimeframe(triggerTimeframeLabel)) {
      notes.add('[ICI] $triggerInfo | Scalping setup ignored (Timeframe < 15M)');
      return null;
    }

    if (_rejectsMinTakeProfitDistance(setup)) {
      notes.add(
          '[ICI] $triggerInfo | rejected: TP distance below ${AppConfig.minTakeProfitPips.toStringAsFixed(0)} pips minimum');
      return null;
    }

    if (_rejectsMinStopLossDistance(setup)) {
      notes.add(
          '[ICI] $triggerInfo | rejected: SL distance below ${AppConfig.minStopLossPips.toStringAsFixed(0)} pips minimum');
      return null;
    }

    if (_rejectsMaxStopLossDistance(setup)) {
      notes.add(
          '[ICI] $triggerInfo | rejected: SL distance above ${AppConfig.maxStopLossPips.toStringAsFixed(0)} pips maximum');
      return null;
    }

    // HTF Alignment — strict consensus, NO exemptions (unlike ICT's
    // Liquidity Sweep Reversal path): both 1H and 4H must agree with each
    // other AND with the trade direction. IctEngine.structureBias is
    // reused so "bias" means the exact same thing everywhere.
    final bias4h = _ict.structureBias(h4);
    final bias1h = _ict.structureBias(h1);
    final htfBias = (bias4h != null && bias1h != null && bias4h == bias1h) ? bias4h : null;
    if (htfBias != setup.direction) {
      notes.add('[ICI] $triggerInfo | rejected: no strict 1H+4H consensus for ${setup.directionLabel} '
          '(1H: ${_biasLabel(bias1h)}, 4H: ${_biasLabel(bias4h)})');
      return null;
    }

    if (_rejectsStaleDrift(setup, livePrice)) {
      notes.add('[ICI] $triggerInfo | rejected: live price drifted too far from Entry');
      return null;
    }

    final score = _iciConfluenceScore(setup, trigger.zone.source);
    setup.confluenceScore = score;
    if (score < AppConfig.minConfluenceScoreIci) {
      notes.add(
          '[ICI] $triggerInfo | Confluence Score $score/100 — rejected (< ${AppConfig.minConfluenceScoreIci} required)');
      return null;
    }

    final withinWindow = _lastIciSignalDirection != null &&
        _lastIciSignalDirectionTime != null &&
        _now().difference(_lastIciSignalDirectionTime!) < AppConfig.directionalDebounceWindow;
    if (withinWindow && setup.direction != _lastIciSignalDirection) {
      notes.add('[ICI] $triggerInfo | Score $score/100 | suppressed — opposes the last ICI signal within the '
          '${AppConfig.directionalDebounceWindow.inMinutes}-min debounce window');
      return null;
    }

    if (!await _passesDxyFilter(setup, '[ICI] $triggerInfo', notes, EngineIds.ici)) return null;

    _lastIciSignalCandleTime = candleTime;
    _lastIciSignalDirection = setup.direction;
    _lastIciSignalDirectionTime = _now();
    _lastIciZoneSignalTime[zoneKey] = _now();

    _log('✅ [ICI] ${setup.directionLabel} Fired @ \$${setup.entry.toStringAsFixed(2)} '
        '(${setup.setupLabel}, Score $score/100, R:R 1:${setup.riskRewardRatio.toStringAsFixed(1)}'
        '${setup.slWasClamped ? ", SL floored to \$${setup.riskDollars.toStringAsFixed(2)}" : ""})');

    // AI commentary + notification are sent centrally by [check], AFTER the
    // Cross-Strategy Conflict Guard — see the matching note in
    // [_evaluateLegacyTrigger].
    return setup;
  }

  /// ICI tier's own Confluence Score (0-100). HTF consensus alignment is a
  /// hard REQUIREMENT to ever reach this point (unlike the legacy/ICT
  /// scores, which award partial credit for a neutral bias), so it's
  /// always full credit here; the last component instead rewards how many
  /// of the three Correction Termination Trigger signals fired together
  /// (encoded in [zoneSource]'s "A + B + C" label) — multiple independent
  /// signals agreeing is a materially stronger setup than just one.
  int _iciConfluenceScore(TradeSetup setup, String zoneSource) {
    var score = 25;

    score += switch (setup.pattern) {
      CandlePattern.bullishEngulfing || CandlePattern.bearishEngulfing => 25,
      CandlePattern.bullishAbsorption || CandlePattern.bearishAbsorption => 25,
      CandlePattern.bullishMomentum || CandlePattern.bearishMomentum => 20,
      CandlePattern.bullishPinbar || CandlePattern.bearishPinbar => 15,
      CandlePattern.doji || CandlePattern.none => 0,
    };

    if (setup.riskRewardRatio >= AppConfig.rrFor(EngineIds.ici)) score += 25;

    final signalCount = ' + '.allMatches(zoneSource).length + 1;
    score += signalCount >= 2 ? 25 : 15;

    return score;
  }

  /// The Ranging Market Module — Zone Bounce Protocol tier (see
  /// zone_bounce_engine.dart, 2026-09-25, explicit request). A SIXTH
  /// independent tier that runs ONLY while there is no clear HTF bias, and
  /// shares none of the Strict Top-Down protocol's gates: it is the mirror
  /// setup (a level that HOLDS, confirmed by a rejection candle), which
  /// that protocol cannot produce by construction.
  ///
  /// Gate order mirrors every other tier's — engine trigger, then the
  /// distance/drift sanity checks, then the score, then the debounces.
  ///
  /// DXY-EXEMPT (2026-09-25, explicit request): unlike the five other
  /// engines, this tier deliberately does NOT call [_passesDxyFilter]. The
  /// DXY Correlation Filter is a directional-bias check ("is the dollar
  /// trending against this trade?"), and this module only ever runs while
  /// there is NO clear HTF directional bias — a range-bound market where a
  /// rejection off a level is judged on its own structure (the range
  /// condition, the zone touch, the rejection pattern), not on where the
  /// dollar happens to be drifting. Every other engine keeps the filter.
  Future<TradeSetup?> _evaluateZoneBounceTrigger({
    required List<Candle> m15,
    required List<HtfZone> htfZones,
    required TradeDirection? htfStructureBias,
    required List<String> notes,
    required double livePrice,
    ImpulseVerdict impulse = ImpulseVerdict.none,
    GuardMode impulseMode = GuardMode.off,
  }) async {
    if (htfStructureBias != null) {
      notes.add('[Range] Clear HTF bias (${htfStructureBias.name}) — ranging module stands down');
      return null;
    }

    // Late-session no-entry window (2026-10-07, explicit request) — checked before any work is done, and
    // before this engine can touch its debounce state, so a blocked scan leaves nothing consumed.
    if (AppConfig.zoneBounceBlockedAt(_now())) {
      notes.add('[Range] No entries ${AppConfig.zoneBounceBlockStartUtc.toString().padLeft(2, '0')}:00-'
          '${AppConfig.zoneBounceBlockEndUtc.toString().padLeft(2, '0')}:00 UTC (late session) — Range Bounce is paused');
      return null;
    }

    // 100% focus on 15M levels (2026-10-07, explicit request): Range Bounce only bounces off 15M levels.
    // Every level — 1H/4H included — still defines the range, i.e. where Take Profit is capped.
    final trigger = _zoneBounce.findTrigger(
      candles: m15,
      zones: htfZones,
      htfBias: htfStructureBias,
      candidateZones: [for (final z in htfZones) if (z.source.startsWith('15M')) z],
    );
    if (trigger == null) {
      notes.add('[Range] No clean rejection at the '
          '${AppConfig.zoneBounceEvaluatedZoneCount} nearest 15M Key Zones this cycle');
      return null;
    }

    // Hot-volatility gate (2026-10-07, explicit request): a bounce fades a move, and when 15M ATR is well above
    // its own 3-day norm the move more often keeps going. Checked right after a bounce is found and before
    // this engine's debounce state is touched, so a blocked scan consumes nothing. No history = no opinion.
    final heat = atrHeat(m15);
    final maxHeat = AppConfig.zoneBounceMaxAtrRatio;
    if (heat != null && heat > maxHeat) {
      notes.add('[Range] Hot volatility — 15M ATR is ${heat.toStringAsFixed(2)}× its 3-day norm '
          '(limit ${maxHeat.toStringAsFixed(2)}×) — bounce skipped');
      _logGuardOnce('rb-heat|${trigger.rejectionCandle.time.toUtc().toIso8601String()}',
          '⛔ [Range] ${trigger.direction == TradeDirection.buy ? 'BUY' : 'SELL'} bounce skipped: hot volatility '
          '(15M ATR ${heat.toStringAsFixed(2)}× its 3-day norm, limit ${maxHeat.toStringAsFixed(2)}×)');
      return null;
    }

    // Fresh-move gate (2026-10-08, explicit request): do not FADE a sharp move. How far did price run over the
    // last two hours AGAINST this trade's direction (a BUY bounce fades a fall, a SELL bounce fades a rally)?
    // Same placement and same guarantees as the gate above: nothing consumed, no history = no opinion.
    final move = recentMoveAtr(m15);
    final maxFade = AppConfig.zoneBounceMaxFadeAtr;
    if (move != null) {
      final against = trigger.direction == TradeDirection.buy ? -move : move;
      if (against > maxFade) {
        final side = trigger.direction == TradeDirection.buy ? 'BUY' : 'SELL';
        notes.add('[Range] Fading a sharp move — price ran ${against.toStringAsFixed(1)} ATR '
            '${trigger.direction == TradeDirection.buy ? 'down' : 'up'} in the last 2h '
            '(limit ${maxFade.toStringAsFixed(1)}) — $side bounce skipped');
        _logGuardOnce('rb-fade|${trigger.rejectionCandle.time.toUtc().toIso8601String()}',
            '⛔ [Range] $side bounce skipped: it would fade a sharp move '
            '(${against.toStringAsFixed(1)} ATR ${trigger.direction == TradeDirection.buy ? 'down' : 'up'} in 2h, '
            'limit ${maxFade.toStringAsFixed(1)})');
        return null;
      }
    }

    final candleTime = trigger.rejectionCandle.time;
    if (_lastZoneBounceSignalCandleTime == candleTime) return null;

    final zoneKey = trigger.zone.price.toStringAsFixed(2);
    final lastZoneFire = _lastZoneBounceZoneSignalTime[zoneKey];
    if (lastZoneFire != null && _now().difference(lastZoneFire) < AppConfig.directionalDebounceWindow) {
      notes.add('[Range] Zone \$$zoneKey already traded within the '
          '${AppConfig.directionalDebounceWindow.inMinutes}-min cooldown');
      return null;
    }

    final setup = _buildZoneBounceSetup(trigger, m15);
    if (setup == null) {
      notes.add('[Range] rejected: invalid risk distance at \$$zoneKey');
      return null;
    }

    final triggerInfo = '15M ${SetupType.rangingBounce.label} '
        '(${trigger.zone.source} \$$zoneKey, ${trigger.pattern.shapeLabel} rejection)';

    // Capping Take Profit at the range's far side can pull the payoff below
    // the configured ratio — the one place this tier's R:R is NOT fixed by
    // construction, so it is checked explicitly rather than assumed.
    if (setup.riskRewardRatio < AppConfig.zoneBounceMinRiskReward) {
      notes.add('[Range] $triggerInfo | rejected: range boundary caps the payoff at '
          '1:${setup.riskRewardRatio.toStringAsFixed(1)} '
          '(< 1:${AppConfig.zoneBounceMinRiskReward} required)');
      return null;
    }
    if (_rejectsMinTakeProfitDistance(setup)) {
      notes.add('[Range] $triggerInfo | rejected: TP distance below '
          '${AppConfig.minTakeProfitPips.toStringAsFixed(0)} pips minimum');
      return null;
    }
    if (_rejectsMinStopLossDistance(setup)) {
      notes.add('[Range] $triggerInfo | rejected: SL distance below '
          '${AppConfig.minStopLossPips.toStringAsFixed(0)} pips minimum');
      return null;
    }
    if (_rejectsMaxStopLossDistance(setup)) {
      notes.add('[Range] $triggerInfo | rejected: SL distance above '
          '${AppConfig.maxStopLossPips.toStringAsFixed(0)} pips maximum');
      return null;
    }
    if (_rejectsStaleDrift(setup, livePrice)) {
      notes.add('[Range] $triggerInfo | rejected: live price drifted too far from Entry');
      return null;
    }

    final score = _zoneBounceConfluenceScore(setup, trigger);
    setup.confluenceScore = score;
    if (score < AppConfig.minConfluenceScoreZoneBounce) {
      notes.add('[Range] $triggerInfo | Confluence Score $score/100 — rejected '
          '(< ${AppConfig.minConfluenceScoreZoneBounce} required)');
      return null;
    }

    // Default (and the no-config behaviour) stays DXY-exempt; the bridge
    // config can opt this engine back in with dxy = block.
    if (StrategyConfig.instance.current.engineDxyMode(EngineIds.rangeBounce) == 'block' &&
        !await _passesDxyFilter(setup, '[Range] $triggerInfo', notes, EngineIds.rangeBounce)) {
      return null;
    }

    final withinWindow = _lastZoneBounceSignalDirection != null &&
        _lastZoneBounceSignalDirectionTime != null &&
        _now().difference(_lastZoneBounceSignalDirectionTime!) < AppConfig.directionalDebounceWindow;
    if (withinWindow && setup.direction != _lastZoneBounceSignalDirection) {
      notes.add('[Range] $triggerInfo | Score $score/100 | suppressed — opposes the last '
          'Range Bounce signal within the '
          '${AppConfig.directionalDebounceWindow.inMinutes}-min debounce window');
      return null;
    }

    // No DXY gate here by design — see this method's doc comment.

    // Fast-Impulse Guard (2026-10-07): a mean-reversion trade AGAINST a fresh impulse is the one this
    // engine must not open. Checked last — right before the debounce state below is touched — so a
    // rejection never burns this engine's candle / zone / direction cooldown, and a SHADOW verdict is
    // only recorded for a setup that really fires.
    if (impulseMode != GuardMode.off) {
      final blocker = impulse.blockerFor(setup.direction);
      if (blocker != null) {
        final why = '${blocker.label} — counter-trend ${setup.directionLabel} restricted until '
            '${formatUtcHm(blocker.restrictUntil)} UTC';
        final key = 'impulse|$impulseMode|${candleTime.toUtc().toIso8601String()}|${setup.direction.name}';
        if (impulseMode == GuardMode.block) {
          notes.add('[Range] $triggerInfo | rejected: Fast-Impulse Guard — $why');
          _logGuardOnce(key, '⛔ [Range] Fast-Impulse Guard rejected ${setup.directionLabel} @ '
              '\$${setup.entry.toStringAsFixed(2)}: $why');
          return null;
        }
        setup.addShadowFlag('${ShadowLayer.impulse}: $why');
        _logGuardOnce(key, '🕶️ [SHADOW] [Range] Fast-Impulse Guard would have rejected ${setup.directionLabel} @ '
            '\$${setup.entry.toStringAsFixed(2)}: $why');
      }
    }

    _lastZoneBounceSignalCandleTime = candleTime;
    _lastZoneBounceSignalDirection = setup.direction;
    _lastZoneBounceSignalDirectionTime = _now();
    _lastZoneBounceZoneSignalTime[zoneKey] = _now();

    _log('✅ [Range] ${setup.directionLabel} Fired @ \$${setup.entry.toStringAsFixed(2)} '
        '(${trigger.zone.source} \$$zoneKey, ${trigger.pattern.shapeLabel} rejection, '
        'Score $score/100, R:R 1:${setup.riskRewardRatio.toStringAsFixed(1)})');

    // AI commentary + notification are sent centrally by [check], AFTER the
    // Engine Priority Resolution — see the matching note in
    // [_evaluateLegacyTrigger].
    return setup;
  }

  /// Prices a Zone Bounce setup. Deliberately not RiskEngine: that engine
  /// anchors its Stop Loss to an HTF zone plus a confirmation candle's wick
  /// and prices TP at a blind ratio, whereas this tier anchors the stop to
  /// the REJECTION wick itself (the level was already traded through by it)
  /// and caps the target at the range's far side. Returns null on a
  /// degenerate risk distance, mirroring RiskEngine's own guard.
  TradeSetup? _buildZoneBounceSetup(ZoneBounceTrigger trigger, List<Candle> m15) {
    final entry = trigger.rejectionCandle.close;
    final atr = _ta.averageTrueRange(m15, period: 14);
    final stopLoss = _zoneBounce.stopLossFor(trigger, atr: atr);
    if (stopLoss == null) return null;

    final takeProfit = _zoneBounce.takeProfitFor(trigger, entry: entry, stopLoss: stopLoss);

    return TradeSetup(
      symbol: AppConfig.symbol,
      direction: trigger.direction,
      timeframeLabel: '15M',
      setupType: SetupType.rangingBounce,
      entry: double.parse(entry.toStringAsFixed(2)),
      stopLoss: double.parse(stopLoss.toStringAsFixed(2)),
      takeProfit: double.parse(takeProfit.toStringAsFixed(2)),
      pattern: trigger.pattern,
      detectedAt: _now().toUtc(),
    );
  }

  /// Zone Bounce's own Confluence Score (0-100).
  ///
  /// Built ONLY from components that actually vary between setups. The ORB
  /// score is the cautionary example found on 2026-09-24: it awards +25 for
  /// "R:R >= the configured ratio" on setups whose R:R is fixed at that
  /// ratio by construction, so every ORB setup scores exactly 100/100 and
  /// its score gate can never reject anything. Here the payoff term is
  /// instead how much of the full target the range's far side leaves room
  /// for — a real, varying property — and no component is constant.
  int _zoneBounceConfluenceScore(TradeSetup setup, ZoneBounceTrigger trigger) {
    // Rejection shape (15-30): an Engulfing candle is a completed transfer
    // of control at the level; a Pinbar is a rejection that still closed
    // inside the prior range; a bare rejection wick is the weakest form.
    var score = switch (trigger.pattern) {
      CandlePattern.bullishEngulfing || CandlePattern.bearishEngulfing => 30,
      CandlePattern.bullishPinbar || CandlePattern.bearishPinbar => 22,
      _ => 15,
    };

    // Zone timeframe (0 or 30) — REVERSED 2026-10-07 (explicit request). It used to reward a 4H level
    // (+30) and a 1H level (+22) over a 15M one (+10), on the instinct that a higher-timeframe level is
    // structurally heavier. For THIS engine the data says the opposite: over ~12 weeks of real MT5 history
    // replayed through the real pipeline, Range Bounce off 1H/4H levels lost money in BOTH the
    // out-of-sample period (09.07-15.09: 70 trades, about 30% wins, -1823 pips) and the recent one
    // (16.09-07.10: 18 trades, about 22% wins, -644 pips), while 15M levels were the profitable ones
    // in the recent period (56 trades, 46% wins, +1830 pips). A bounce off a big level is more often the
    // start of a break than a hold, so the higher timeframes get no credit here and all of the zone
    // weight goes to 15M. (The ranking between competing candidates is ZoneBounceEngine._rank, not this
    // score, and is untouched.)
    score += trigger.zone.source.startsWith('15M') ? 30 : 0;

    // How cleanly the wick tested the level (0-20): a wick driven decisively
    // INTO the level and thrown back is a stronger test than a graze.
    final penetration =
        (trigger.isBuy ? trigger.zone.price - trigger.rejectionExtreme : trigger.rejectionExtreme - trigger.zone.price)
            .clamp(0.0, double.infinity);
    score += (penetration / AppConfig.zoneBounceTouchDollars * 20).clamp(0.0, 20.0).round();

    // Room to the range's far side (0-20): the share of the full configured
    // target this setup can reach before running into the opposing boundary.
    final ratioShare = (setup.riskRewardRatio / AppConfig.rrFor(EngineIds.rangeBounce)).clamp(0.0, 1.0);
    score += (ratioShare * 20).round();

    return score.clamp(0, 100);
  }

  /// The Asia Opening Range Breakout tier (see orb_engine.dart; rebuilt 2026-10-09 as the fifth engine, replacing
  /// the London/New York ORB) — never reads htfZones, a candlestick pattern or a trend gate: the replayed rules
  /// had none, and a 4H gate is what the old engine used. Its own [OrbRange.key]-based "Single Trade per Range"
  /// state ([_consumedOrbRanges]) plays the role every other tier's candle/zone debounce does — set ONLY once a
  /// trigger actually fires (survives every gate below), never merely because one was found, so a candidate
  /// rejected this cycle (e.g. stop too wide) stays eligible for a later cycle rather than burning the range's one
  /// shot for nothing.
  Future<TradeSetup?> _evaluateOrbTrigger({
    required List<Candle> candles5m,
    required TradeDirection? bias1h,
    required DateTime nowUtc,
    required List<String> notes,
    required double livePrice,
  }) async {
    if (candles5m.isEmpty) {
      notes.add('[ORB] Waiting on 5M candles');
      return null;
    }

    for (final session in OrbSession.values) {
      final range = _orb.computeRange(candles5m, session, nowUtc);
      if (range == null) {
        notes.add('[ORB] ${session.label} — Opening Range not formed yet');
        continue;
      }
      if (_consumedOrbRanges.contains(range.key)) {
        notes.add('[ORB] ${session.label} — range already traded today');
        continue;
      }

      // The range's validity window must still be OPEN right now — checked
      // BEFORE findTrigger, not after (2026-09-25 fix).
      //
      // findTrigger only bounds WHEN THE PATTERN MAY OCCUR: it drops
      // candles past the deadline, so the breakout and its retest must
      // both fall inside the window. That is necessary but NOT sufficient,
      // and the original comment here claimed otherwise. Nothing stopped a
      // pattern that legitimately completed in-window from being ENTERED
      // arbitrarily long afterwards, because findTrigger is stateless and
      // re-derives the same in-window trigger from the candle history on
      // every later cycle.
      //
      // It happened live: a New York trigger whose retest completed by
      // 14:15 UTC fired as a real entry at 22:15 UTC — eight hours past
      // its own deadline — three seconds after the One Active Trade Limit
      // released. The stale-drift guard (maxStalePriceDriftDollars) passed
      // it only because price had wandered back within $1.50 of the entry
      // by coincidence; that guard measures PRICE distance, never elapsed
      // TIME, so it cannot be relied on to catch this.
      if (!nowUtc.isBefore(_orb.deadline(range))) {
        notes.add('[ORB] ${session.label} range \$${range.low.toStringAsFixed(2)}-\$${range.high.toStringAsFixed(2)} '
            '— expired (entry window closed at ${AppConfig.orbEntryUntilUtcHour.toString().padLeft(2, '0')}:00 UTC), '
            'no trade today');
        continue;
      }

      final trigger = _orb.findTrigger(candles5m, range);
      if (trigger == null) {
        notes.add('[ORB] ${session.label} range \$${range.low.toStringAsFixed(2)}-\$${range.high.toStringAsFixed(2)} '
            '— no confirmed retest yet');
        continue;
      }

      final triggerInfo = '5M ${SetupType.orbBreakout.label} (${session.label}, retest confirmed)';

      final setup = _buildOrbSetup(trigger);
      if (setup == null) {
        notes.add('[ORB] $triggerInfo | rejected: invalid risk distance (Entry == Stop Loss)');
        continue;
      }

      if (_rejectsMinTakeProfitDistance(setup)) {
        notes.add('[ORB] $triggerInfo | rejected: TP distance below '
            '${AppConfig.minTakeProfitPips.toStringAsFixed(0)} pips minimum');
        continue;
      }
      if (_rejectsMinStopLossDistance(setup)) {
        notes.add('[ORB] $triggerInfo | rejected: SL distance below '
            '${AppConfig.minStopLossPips.toStringAsFixed(0)} pips minimum');
        continue;
      }
      if (_rejectsMaxStopLossDistance(setup)) {
        notes.add('[ORB] $triggerInfo | rejected: SL distance above '
            '${AppConfig.maxStopLossPips.toStringAsFixed(0)} pips maximum');
        continue;
      }
      if (_rejectsStaleDrift(setup, livePrice)) {
        notes.add('[ORB] $triggerInfo | rejected: live price drifted too far from Entry');
        continue;
      }

      final score = _orbConfluenceScore(trigger, candles5m, bias1h: bias1h);
      setup.confluenceScore = score;
      if (score < AppConfig.minConfluenceScoreOrb) {
        notes.add('[ORB] $triggerInfo | Confluence Score $score/100 — rejected '
            '(< ${AppConfig.minConfluenceScoreOrb} required)');
        continue;
      }

      if (!await _passesDxyFilter(setup, '[ORB] $triggerInfo', notes, EngineIds.orb)) continue;

      _consumedOrbRanges.add(range.key);
      _log('✅ [ORB] ${setup.directionLabel} Fired @ \$${setup.entry.toStringAsFixed(2)} '
          '(${session.label} range \$${range.low.toStringAsFixed(2)}-\$${range.high.toStringAsFixed(2)}, '
          'Score $score/100, R:R 1:${setup.riskRewardRatio.toStringAsFixed(1)})');

      // AI commentary + notification are sent centrally by [check], AFTER
      // the Cross-Strategy Conflict Guard — see the matching note in
      // [_evaluateLegacyTrigger].
      return setup;
    }
    return null;
  }

  /// ORB's own risk sizing — deliberately NOT RiskEngine, whose SL logic is
  /// built around a candlestick-pattern confirmation candle and an HTF
  /// zone, neither of which ORB has ("Allow dynamic/configurable Stop Loss
  /// and Take Profit settings", explicit request). Dynamic by default: SL
  /// sits behind the range's OPPOSITE side (the breakout thesis is only
  /// proven wrong once price has retraced the entire range) plus
  /// [AppConfig.slBufferDollars], and TP sits at the engine's own `rr` from the bridge config, or
  /// [AppConfig.orbRiskRewardDefault] (2.0) without one — never the global default, which the replayed
  /// Asia ORB did not use; either side switches to a fixed pip
  /// distance from Entry instead when its own AppConfig override is set
  /// (> 0). Returns null on a degenerate (zero) risk distance, mirroring
  /// RiskEngine.buildTradeSetup's own guard.
  TradeSetup? _buildOrbSetup(OrbTrigger trigger) {
    final range = trigger.range;
    final bullish = trigger.direction == TradeDirection.buy;
    final entry = trigger.entryCandle.close;

    final slPips = AppConfig.orbStopLossPipsOverride;
    final stopLoss = slPips > 0
        ? (bullish ? entry - slPips * TradeSetup.dollarsPerPip : entry + slPips * TradeSetup.dollarsPerPip)
        : (bullish ? range.low - AppConfig.slBufferDollars : range.high + AppConfig.slBufferDollars);

    final riskDistance = (entry - stopLoss).abs();
    if (riskDistance <= 0) return null;

    final tpPips = AppConfig.orbTakeProfitPipsOverride;
    final rr = StrategyConfig.instance.current.engineRiskReward(EngineIds.orb) ?? AppConfig.orbRiskRewardDefault;
    final takeProfit = tpPips > 0
        ? (bullish ? entry + tpPips * TradeSetup.dollarsPerPip : entry - tpPips * TradeSetup.dollarsPerPip)
        : (bullish ? entry + rr * riskDistance : entry - rr * riskDistance);

    return TradeSetup(
      symbol: AppConfig.symbol,
      direction: trigger.direction,
      timeframeLabel: '5M',
      setupType: SetupType.orbBreakout,
      entry: double.parse(entry.toStringAsFixed(2)),
      stopLoss: double.parse(stopLoss.toStringAsFixed(2)),
      takeProfit: double.parse(takeProfit.toStringAsFixed(2)),
      pattern: bullish ? CandlePattern.bullishMomentum : CandlePattern.bearishMomentum,
      detectedAt: _now().toUtc(),
    );
  }

  /// ORB's own Confluence Score (60-100) — INFORMATIONAL since 2026-10-09: every setup that reaches it already met
  /// all of the replayed rules (break, confirmed retest, stop inside the limits), so the floor of 60 sits above
  /// [AppConfig.minConfluenceScoreOrb] and the score never rejects; it still varies, so a weaker setup reads weaker.
  /// The 4H component of the old London/New York ORB is gone with its trend gate.
  ///   base 60        — confirmed break + mandatory retest
  ///   1H bias   0-20 — aligned 20, neutral 10, opposed 0
  ///   range     0-20 — Opening Range height vs 5M ATR(14): ideal 20,
  ///                    acceptable 10, too narrow/wide 0
  int _orbConfluenceScore(
    OrbTrigger trigger,
    List<Candle> candles5m, {
    required TradeDirection? bias1h,
  }) {
    int alignment(TradeDirection? bias, int aligned, int neutral) =>
        bias == null ? neutral : (bias == trigger.direction ? aligned : 0);

    var score = 60;
    score += alignment(bias1h, 20, 10);

    final range = trigger.range;
    final atr = _ta.averageTrueRange(
      candles5m.where((c) => c.time.isBefore(range.rangeEnd)).toList(),
    );
    if (atr != null && atr > 0) {
      final heightAtr = (range.high - range.low) / atr;
      if (heightAtr >= AppConfig.orbIdealRangeMinAtr && heightAtr <= AppConfig.orbIdealRangeMaxAtr) {
        score += 20;
      } else if (heightAtr >= AppConfig.orbAcceptableRangeMinAtr && heightAtr <= AppConfig.orbAcceptableRangeMaxAtr) {
        score += 10;
      }
    }
    return score.clamp(0, 100);
  }

  /// The Breakout/Momentum strategy tier (see breakout_momentum_engine.dart)
  /// — runs with its OWN debounce state (the `_lastBreakout*` fields),
  /// entirely separate from every other tier's.
  ///
  /// Rebuilt 2026-09-22 to an explicit 11-point specification. The engine
  /// itself owns steps 1-5 (Important Level -> Breakout Candle -> Momentum
  /// -> Failed-Breakout Protection -> Retest -> don't-chase distance); this
  /// method owns the gates that need data the engine is deliberately not
  /// given, in the spec's own decision order:
  ///
  ///   Session  -> only London/New York (configurable UTC inputs), since
  ///               "للذهب، لا أترك النظام يعمل طوال اليوم". Checked FIRST
  ///               because it's free and skips the whole tier.
  ///   HTF      -> 1H swing-structure bias (IctEngine.structureBias), as a
  ///               score bonus by default, a hard block only if asked.
  ///   DXY      -> same score/block/off choice, same reasoning.
  ///   News     -> no NEW entry inside the high-impact USD blackout window.
  ///
  /// Risk is priced from the LEVEL and ATR rather than RiskEngine's
  /// candle-wick anchor (spec point 10 — see [_buildBreakoutSetup]).
  Future<TradeSetup?> _evaluateBreakoutTrigger({
    required List<Candle> candles5m,
    required List<Candle> candles15m,
    required List<Candle> candlesH1,
    required List<HtfZone> htfZones,
    required DateTime nowUtc,
    required List<String> notes,
    required double livePrice,
  }) async {
    if (candles5m.isEmpty) {
      notes.add('[Breakout] Waiting on 5M candles');
      return null;
    }

    // --- Spec 6: Session Filter (checked first — skips the whole tier) ---
    if (AppConfig.breakoutSessionFilterEnabled && !_inBreakoutSession(nowUtc)) {
      notes.add('[Breakout] Outside the enabled session windows '
          '(${AppConfig.breakoutAsianSessionEnabled ? "Asian/" : ""}London/New York) — no trade');
      return null;
    }

    // --- Spec 1: Important Level ---
    final levels = _breakout.prioritize([
      ..._breakout.htfLevels(htfZones),
      ..._breakout.previousDayLevels(candlesH1, nowUtc),
      ..._breakout.previousSessionLevels(candles15m, nowUtc),
      ..._breakout.swingLevels(candles15m),
      ..._breakout.openingRangeLevels(candles15m, nowUtc),
    ]);
    if (levels.isEmpty) {
      notes.add('[Breakout] No structural levels available yet');
      return null;
    }

    // --- Spec 2-5 + 11: the engine's own breakout/momentum/retest chain ---
    final requireRetest = AppConfig.breakoutRequireRetest;
    final trigger = _breakout.findTrigger(candles5m, levels, requireRetest: requireRetest);
    if (trigger == null) {
      notes.add('[Breakout] ${levels.length} level(s) tracked — no confirmed '
          '${requireRetest ? "breakout + retest" : "breakout"} this cycle');
      return null;
    }

    final patternLabel = switch (trigger.entryKind) {
      BreakoutEntryKind.immediate => 'breakout',
      BreakoutEntryKind.retest => 'breakout + retest confirmed',
      BreakoutEntryKind.failedReversal => 'FAILED-BREAKOUT REVERSAL, confirmed',
    };
    final triggerInfo = '5M ${SetupType.breakoutMomentum.label} — ${trigger.level.label} '
        '(\$${trigger.level.price.toStringAsFixed(2)}, $patternLabel)';

    // Debounce: don't fire twice for the same M5 candle close.
    final candleTime = trigger.candle.time;
    if (_lastBreakoutSignalCandleTime == candleTime) {
      notes.add('[Breakout] $triggerInfo | already signaled this candle');
      return null;
    }

    // Per-level cooldown — same convention as ICT/ICI's per-zone cooldown.
    final levelKey = '${trigger.level.kind.name}@${trigger.level.price.toStringAsFixed(2)}';
    final lastLevelFire = _lastBreakoutZoneSignalTime[levelKey];
    if (lastLevelFire != null && _now().difference(lastLevelFire) < AppConfig.directionalDebounceWindow) {
      notes.add('[Breakout] $triggerInfo | suppressed — level already signaled within the '
          '${AppConfig.directionalDebounceWindow.inMinutes}-min cooldown');
      return null;
    }

    // --- Spec 9: HTF Direction ---
    final htfBias = _ict.structureBias(candlesH1);
    final htfAligned = htfBias != null && htfBias == trigger.direction;
    if (AppConfig.breakoutHtfMode == 'block' && htfBias != null && !htfAligned) {
      notes.add('[Breakout] $triggerInfo | rejected: opposes the 1H structure bias '
          '(${_biasLabel(htfBias)}) — BREAKOUT_HTF_MODE=block');
      return null;
    }

    // --- Spec 10: ATR/structure risk ---
    final setup = _buildBreakoutSetup(trigger);
    if (setup == null) {
      notes.add('[Breakout] $triggerInfo | rejected: invalid risk distance (Entry == Stop Loss)');
      return null;
    }

    if (_rejectsMinTakeProfitDistance(setup)) {
      notes.add('[Breakout] $triggerInfo | rejected: TP distance below '
          '${AppConfig.minTakeProfitPips.toStringAsFixed(0)} pips minimum');
      return null;
    }
    if (_rejectsMinStopLossDistance(setup)) {
      notes.add('[Breakout] $triggerInfo | rejected: SL distance below '
          '${AppConfig.minStopLossPips.toStringAsFixed(0)} pips minimum');
      return null;
    }
    if (_rejectsMaxStopLossDistance(setup)) {
      notes.add('[Breakout] $triggerInfo | rejected: SL distance above '
          '${AppConfig.maxStopLossPips.toStringAsFixed(0)} pips maximum');
      return null;
    }
    if (_rejectsStaleDrift(setup, livePrice)) {
      notes.add('[Breakout] $triggerInfo | rejected: live price drifted too far from Entry');
      return null;
    }

    // --- Spec 7: DXY (score by default, block only on request) ---
    final engineDxy = StrategyConfig.instance.current.engineDxyMode(EngineIds.breakout);
    final dxyMode = switch (engineDxy) {
      'block' => 'block',
      'score' => 'score',
      'off' || 'exempt' => 'off',
      _ => AppConfig.breakoutDxyMode,
    };
    var dxyConfirmed = false;
    if (dxyMode != 'off') {
      dxyConfirmed = await _dxy.confirms(setup.direction);
      if (!dxyConfirmed && dxyMode == 'block') {
        notes.add('[Breakout] $triggerInfo | rejected: DXY opposes this ${setup.directionLabel} '
            '— BREAKOUT_DXY_MODE=block');
        return null;
      }
    }

    final score = _breakoutConfluenceScore(
      setup: setup,
      trigger: trigger,
      htfAligned: htfAligned,
      dxyConfirmed: dxyConfirmed,
    );
    setup.confluenceScore = score;
    if (score < AppConfig.minConfluenceScoreBreakout) {
      notes.add('[Breakout] $triggerInfo | Confluence Score $score/100 — rejected '
          '(< ${AppConfig.minConfluenceScoreBreakout} required)');
      return null;
    }

    final withinWindow = _lastBreakoutSignalDirection != null &&
        _lastBreakoutSignalDirectionTime != null &&
        _now().difference(_lastBreakoutSignalDirectionTime!) < AppConfig.directionalDebounceWindow;
    if (withinWindow && setup.direction != _lastBreakoutSignalDirection) {
      notes.add('[Breakout] $triggerInfo | Score $score/100 | suppressed — opposes the last Breakout signal '
          'within the ${AppConfig.directionalDebounceWindow.inMinutes}-min debounce window');
      return null;
    }

    // --- Spec 8: News Filter (last gate before entry) ---
    if (AppConfig.breakoutNewsFilterEnabled) {
      final blackout = Duration(minutes: AppConfig.breakoutNewsBlackoutMinutes);
      final event = await _newsCalendar.blackoutEvent(blackout, now: _now());
      if (event != null) {
        final minutesAway = event.timeUtc.difference(_now().toUtc()).inMinutes;
        notes.add('[Breakout] $triggerInfo | rejected: high-impact USD news blackout — '
            '${event.name} ${minutesAway >= 0 ? "in ${minutesAway}m" : "${-minutesAway}m ago"}');
        _log('[Breakout] Signal skipped: high-impact news blackout (${event.name}) — no new entry within '
            '${AppConfig.breakoutNewsBlackoutMinutes} minutes of the release');
        return null;
      }
    }

    _lastBreakoutSignalCandleTime = candleTime;
    _lastBreakoutSignalDirection = setup.direction;
    _lastBreakoutSignalDirectionTime = _now();
    _lastBreakoutZoneSignalTime[levelKey] = _now();

    _log('✅ [Breakout] ${setup.directionLabel} Fired @ \$${setup.entry.toStringAsFixed(2)} '
        '(session ${_breakoutSessions(nowUtc).join("+")}, '
        '${trigger.level.label}, $patternLabel, '
        '${trigger.fakeoutExtreme != null ? "trap extreme \$${trigger.fakeoutExtreme!.toStringAsFixed(2)} "
            "(${trigger.trapDistanceAtr!.toStringAsFixed(2)} ATR from entry), " : ""}'
        'ATR(14) \$${trigger.atr.toStringAsFixed(2)}, '
        'range x${trigger.rangeExpansion.toStringAsFixed(2)}, '
        '${trigger.entryDistanceAtr.toStringAsFixed(2)} ATR past the level, '
        'HTF ${htfAligned ? "aligned" : _biasLabel(htfBias)}, '
        'DXY ${dxyMode == 'off' ? "off" : (dxyConfirmed ? "confirms" : "neutral/against")}, '
        'Score $score/100, R:R 1:${setup.riskRewardRatio.toStringAsFixed(1)})');

    // AI commentary + notification are sent centrally by [check], AFTER the
    // Cross-Strategy Conflict Guard — see the matching note in
    // [_evaluateLegacyTrigger].
    return setup;
  }

  /// Spec 6 — is [nowUtc] inside any enabled session window? Each is a
  /// plain same-day UTC range; one configured to wrap past midnight
  /// (end <= start) is treated as disabled rather than silently matching
  /// everything. The Asian window is opt-in on its own flag
  /// ([AppConfig.breakoutAsianSessionEnabled]) so its effect stays
  /// measurable separately from London/New York.
  bool _inBreakoutSession(DateTime nowUtc) => _breakoutSessions(nowUtc).isNotEmpty;

  /// Which enabled session window(s) [nowUtc] falls in — logged on every
  /// fired setup so "how did the Asian session actually do?" is answerable
  /// straight from the log later, without re-deriving it from timestamps.
  List<String> _breakoutSessions(DateTime nowUtc) {
    final minutes = nowUtc.hour * 60 + nowUtc.minute;
    bool inWindow(int start, int end) => end > start && minutes >= start && minutes < end;
    return [
      if (AppConfig.breakoutAsianSessionEnabled &&
          inWindow(AppConfig.breakoutAsianStartUtcMinutes, AppConfig.breakoutAsianEndUtcMinutes))
        'Asian',
      if (inWindow(AppConfig.breakoutLondonStartUtcMinutes, AppConfig.breakoutLondonEndUtcMinutes)) 'London',
      if (inWindow(AppConfig.breakoutNewYorkStartUtcMinutes, AppConfig.breakoutNewYorkEndUtcMinutes)) 'New York',
    ];
  }

  /// Spec 10 — Breakout/Momentum's own risk pricing, deliberately NOT
  /// RiskEngine (whose Stop Loss is anchored to a candlestick-pattern
  /// confirmation candle's wick, which a breakout entry doesn't have):
  ///
  ///   Entry = the trigger candle's close.
  ///   SL    = [AppConfig.breakoutSlAtrMultiplier] x ATR(14) BEYOND the
  ///           broken level — structure AND volatility together, never a
  ///           fixed dollar distance. Putting it past the LEVEL (not past
  ///           the entry) is what makes it a real invalidation: price
  ///           closing back through the level is exactly the
  ///           Failed-Breakout case the trade no longer has a thesis for.
  ///   TP    = [AppConfig.breakoutTakeProfitRMultiple] x that risk — a
  ///           tunable R multiple (test 1.5R/2R/2.5R/3R), not an
  ///           assumption baked into the code.
  TradeSetup? _buildBreakoutSetup(BreakoutTrigger trigger) {
    final bullish = trigger.direction == TradeDirection.buy;
    final entry = trigger.candle.close;
    final slBuffer = AppConfig.breakoutSlAtrMultiplier * trigger.atr;
    // A Failed-Breakout Reversal anchors to the TRAP's own extreme instead
    // of the level: price getting back through the high/low the fakeout
    // actually reached is what proves the break was real after all, and
    // that extreme always sits beyond the level on the losing side.
    final anchor = trigger.fakeoutExtreme ?? trigger.level.price;
    final stopLoss = bullish ? anchor - slBuffer : anchor + slBuffer;

    final riskDistance = (entry - stopLoss).abs();
    if (riskDistance <= 0) return null;

    final reward = AppConfig.breakoutTakeProfitRMultiple * riskDistance;
    final takeProfit = bullish ? entry + reward : entry - reward;

    return TradeSetup(
      symbol: AppConfig.symbol,
      direction: trigger.direction,
      timeframeLabel: '5M',
      setupType: SetupType.breakoutMomentum,
      entry: double.parse(entry.toStringAsFixed(2)),
      stopLoss: double.parse(stopLoss.toStringAsFixed(2)),
      takeProfit: double.parse(takeProfit.toStringAsFixed(2)),
      pattern: bullish ? CandlePattern.bullishMomentum : CandlePattern.bearishMomentum,
      detectedAt: _now().toUtc(),
    );
  }

  /// Breakout/Momentum's own Confluence Score (0-100), rebuilt 2026-09-22
  /// around the new spec's own hierarchy of evidence. Every component is
  /// something the setup actually EARNED rather than a flat participation
  /// bonus, so the score genuinely separates a textbook setup from a
  /// marginal one:
  ///
  ///   Level importance        0-30  — multi-touch HTF S/R down to Opening
  ///                                   Range (see BreakoutLevelKind.importance)
  ///   Retest confirmed        0-20  — the spec's preferred entry mode
  ///   Momentum expansion      0-15  — how far past the required range
  ///                                   expansion the breakout candle ran
  ///   Entry proximity         0-10  — the closer to the level, the better
  ///                                   the entry (inverse of "chasing")
  ///   HTF alignment           0-15  — 1H structure agrees
  ///   DXY confirmation        0-10  — the cross-asset check agrees
  ///   Reward target reached   0-10  — R:R met the configured multiple
  int _breakoutConfluenceScore({
    required TradeSetup setup,
    required BreakoutTrigger trigger,
    required bool htfAligned,
    required bool dxyConfirmed,
  }) {
    var score = trigger.level.kind.importance;

    if (trigger.retestConfirmed) score += 20;
    // A Failed-Breakout Reversal earns the same structural credit for a
    // different reason: the confirmation candle extending the rejection is
    // its equivalent of a held retest — price has now proven the level
    // twice (once by rejecting the break, once by following through).
    if (trigger.isFailedReversal) score += 20;

    // Momentum: full credit at 2x the recent average range, scaled from the
    // configured minimum expansion up to there.
    final minExpansion = AppConfig.breakoutMinRangeToAvgRatio;
    final expansionHeadroom = (trigger.rangeExpansion - minExpansion) / max(0.1, 2.0 - minExpansion);
    score += (15 * expansionHeadroom.clamp(0.0, 1.0)).round();

    // Proximity: full credit entering right at the Stop Loss anchor, none
    // at the configured maximum chase distance. For a reversal that anchor
    // is the trap's extreme, not the level — the same distinction the risk
    // cap itself rests on.
    final chased = trigger.isFailedReversal
        ? (trigger.trapDistanceAtr ?? 0) / max(0.01, AppConfig.breakoutReversalMaxTrapDistanceAtr)
        : trigger.entryDistanceAtr / max(0.01, AppConfig.breakoutMaxEntryDistanceAtr);
    score += (10 * (1 - chased.clamp(0.0, 1.0))).round();

    if (htfAligned) score += 15;
    if (dxyConfirmed) score += 10;
    if (setup.riskRewardRatio >= AppConfig.breakoutTakeProfitRMultiple) score += 10;

    return score.clamp(0, 100);
  }

  /// Rule 4 — Confluence Score (0-100): HTF trend alignment + reversal-
  /// pattern strength + R:R + organic-vs-clamped SL. Rejected below
  /// AppConfig.minConfluenceScore (50) — minConfluenceScoreScalping (70)
  /// no longer applies to anything since Scalping strategies were
  /// disabled (2026-09-14).
  int _confluenceScore(TradeSetup setup, TradeDirection? bias) {
    var score = 0;

    // HTF Trend Alignment (0-25): setup direction agrees with 4H bias.
    if (bias == setup.direction) {
      score += 25;
    } else if (bias == null) {
      score += 10; // neutral — no tailwind, but doesn't contradict either
    }
    // else: opposes bias — 0 points here (Rule 3 also independently
    // guards against emitting a signal that flips direction too soon).

    // Strong Reversal Pattern on 15M (0-25): Engulfing > Pinbar.
    score += switch (setup.pattern) {
      CandlePattern.bullishEngulfing || CandlePattern.bearishEngulfing => 25,
      CandlePattern.bullishAbsorption || CandlePattern.bearishAbsorption => 25,
      CandlePattern.bullishMomentum || CandlePattern.bearishMomentum => 20,
      CandlePattern.bullishPinbar || CandlePattern.bearishPinbar => 15,
      CandlePattern.doji || CandlePattern.none => 0,
    };

    // Clean R:R >= 1:2 (0-25) — hard-enforced by RiskEngine, so this is
    // really "did it actually reach the configured ratio" rather than a
    // free 25 points.
    if (setup.riskRewardRatio >= AppConfig.rrFor(EngineIds.htfRetest)) score += 25;

    // Structural SL integrity (25): there's no minimum-SL floor/clamp
    // anymore (2026-09-10 — the user sizes their own lot to the real pip
    // distance instead), so every setup's SL is always the organic
    // structural distance — full credit every time.
    score += 25;

    return score;
  }

  /// Consecutive losing trades (negative pips, manual closes included)
  /// closed today in UTC, counted back from the most recent close. A win or
  /// break-even ends the streak.
  int _todayLossStreak(List<TradeSetup> history, DateTime nowUtc) {
    final startOfDay = DateTime.utc(nowUtc.year, nowUtc.month, nowUtc.day);
    final closedToday = history
        .where((s) =>
            !s.isMissed &&
            s.outcome != TradeOutcome.open &&
            s.closedAt != null &&
            !s.closedAt!.toUtc().isBefore(startOfDay))
        .toList()
      ..sort((a, b) => b.closedAt!.compareTo(a.closedAt!));
    var streak = 0;
    for (final setup in closedToday) {
      if ((setup.pips ?? 0) >= 0) break;
      streak++;
    }
    return streak;
  }

  /// Simple momentum read over the last ~20 4H candles (~3.3 days): net
  /// direction of the move, or null if the range is too flat to call.
  TradeDirection? _fourHourBias(List<Candle> h4) {
    if (h4.length < 10) return null;
    final window = h4.length > 20 ? h4.sublist(h4.length - 20) : h4;
    final diff = window.last.close - window.first.close;
    if (diff.abs() < AppConfig.slBufferDollars) return null;
    return diff > 0 ? TradeDirection.buy : TradeDirection.sell;
  }

  /// Same read as [_fourHourBias], applied to 1H instead of 4H (last ~20
  /// 1H candles, ~20 hours) — added 2026-09-10 so the HTF Trend Alignment
  /// gate checks the more immediate 1H trend too, not just the slower 4H
  /// one: a setup can agree with the 4H macro direction while still
  /// fighting a clear, more recent 1H move against it.
  TradeDirection? _hourlyBias(List<Candle> h1) {
    if (h1.length < 10) return null;
    final window = h1.length > 20 ? h1.sublist(h1.length - 20) : h1;
    final diff = window.last.close - window.first.close;
    if (diff.abs() < AppConfig.slBufferDollars) return null;
    return diff > 0 ? TradeDirection.buy : TradeDirection.sell;
  }

  String _biasLabel(TradeDirection? bias) => switch (bias) {
        TradeDirection.buy => 'bullish',
        TradeDirection.sell => 'bearish',
        null => 'neutral',
      };
}

/// Outcome of a manual "Close Trade" request.
class ManualCloseResult {
  /// The trade is now closed in the app's history.
  final bool closed;

  /// The REAL MT5 position was closed by this request.
  final bool brokerClosed;

  /// A sentence fit to show the user.
  final String message;
  const ManualCloseResult({required this.closed, required this.message, this.brokerClosed = false});
}
