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
import 'ict_engine.dart';
import 'impulse_correction_engine.dart';
import 'news_calendar_service.dart';
import 'notifier_service.dart';
import 'price_alert_service.dart';
import 'risk_engine.dart';
import 'ta_engine.dart';

class _CachedCandles {
  final DateTime fetchedAt;
  final List<Candle> candles;
  final FeedSource? source; // null in mock mode
  const _CachedCandles(this.fetchedAt, this.candles, this.source);
}

/// [isFresh] is false when these candles came from the cache after a failed
/// refresh (stale-while-revalidate).
typedef _CandleFetch = ({List<Candle> candles, bool isFresh, FeedSource? source});

/// Result of a single check cycle: a human-readable status and the
/// setup(s) found this cycle, if any — one per independent strategy tier
/// (legacy/ICT/ICI) that fired, all evaluated against CLOSED 15M candles.
/// Setups are NOT yet AI-annotated, notified or persisted — MonitorEngine
/// does that after de-duplicating them against the stored history.
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
///     fetch anywhere in this pipeline). A setup triggers on EITHER a
///     valid Reversal/Retest price-action confirmation (Pinbar/Engulfing)
///     OR a Momentum/Breakout expansion candle when no reversal pattern
///     exists (TaEngine.findExecutionTrigger — Dual-Mode Signal Engine,
///     2026-09-09) — but ONLY when price sits within a flexible $2.00
///     (20 pip) Interest Area of the nearest HTF zone
///     (AppConfig.interestZoneBufferDollars, 2026-09-09), replacing the
///     old rigid $15 gate — except the Reversal/Retest path itself, which
///     now (2026-09-10, High-Probability Gating) requires genuine
///     Institutional Absorption at the zone regardless of the buffer (see
///     TaEngine._isInstitutionalAbsorption): the wick must break the
///     zone's exact price while the body closes strictly behind it. When
///     that finds nothing, 15M Higher Low / Lower High Absorption
///     (TaEngine.find15mAbsorptionTrigger, 2026-09-10) is tried as a
///     fallback — a two-candle structural pattern (not a single candle's
///     wick/body shape) at the same HTF zones, priced with SL anchored to
///     the PREVIOUS 15M candle's own low/high per its own definition.
///  4. Every triggered setup is priced by RiskEngine (SL is always the
///     organic structural distance — no minimum-SL floor at the RiskEngine
///     level, 2026-09-10; a blanket AppConfig.minStopLossPips/
///     minTakeProfitPips REJECTION floor was added on top 2026-09-14, see
///     _rejectsMinStopLossDistance/_rejectsMinTakeProfitDistance), then
///     must pass, in order: those two distance filters, a Scalping
///     Timeframe Guard (_rejectsScalpingTimeframe — dead in practice now
///     that 1M/5M are never fetched, kept as an explicit defense-in-depth
///     check), an HTF Trend Alignment gate — setup direction must not
///     oppose a clear 1H OR 4H bias (2026-09-10: checks both now, not just
///     4H), UNLESS it's a Break & Retest (SetupType.htfRetest) or anchored
///     to a larger-timeframe (1H) zone — 15M Absorption gets NEITHER
///     exemption (2026-09-10: removed after 3/3 countertrend Absorption
///     BUYs fired through the 1H-zone loophole and all lost), so a
///     countertrend 15M Absorption can never fire — a Trendline
///     Clear-Path gate (2026-09-10: a Trendline-sourced trigger is
///     rejected if another HTF zone sits between Entry and TP), Rule 2
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
  final RiskEngine _risk = RiskEngine();
  final AiEngine _ai = AiEngine();
  final NotifierService _notifier = NotifierService();
  final PriceAlertService _alerts = PriceAlertService();
  final NewsCalendarService _newsCalendar = NewsCalendarService();

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

  // Per-timeframe candle cache — persists across check() cycles (this
  // instance lives for the whole monitoring session). An entry is reused
  // only while BOTH its TTL hasn't expired AND no candle boundary of that
  // timeframe has passed since it was fetched — so a freshly closed 15M/1H/
  // 4H candle is always picked up on the very next cycle, while 1H/4H are
  // not re-downloaded every 30 seconds in between.
  final Map<int, _CachedCandles> _candleCache = {};
  static const Map<int, Duration> _cacheTtl = {
    15: Duration(seconds: 55),
    60: Duration(minutes: 15),
    240: Duration(minutes: 60),
  };

  /// Prints the reasoning behind every accept/reject decision this cycle
  /// makes, routed through AppLogger (persisted, visible in System Logs from
  /// either isolate, and in `adb logcat`).
  void _log(String message) => AppLogger.log(message);

  /// Minimum Take-Profit Distance Filter (2026-09-14, explicit request;
  /// threshold documented on AppConfig.minTakeProfitPips) — shared by all
  /// three strategy evaluators so every path is held to the same floor.
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

  /// Rule 2 — Signal Staleness: shared by all three strategies.
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

  /// Scalping Timeframe Guard — defense-in-depth only; no strategy is given
  /// 1M/5M candles anymore (2026-09-14).
  bool _rejectsScalpingTimeframe(String triggerTimeframeLabel) {
    if (triggerTimeframeLabel == '1M' || triggerTimeframeLabel == '5M') {
      _log('Scalping setup ignored (Timeframe < 15M).');
      return true;
    }
    return false;
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
        '($rangeLabel) | Searching Reversal / Momentum...');
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
    try {
      await HistoryStore.mutate((history) {
        for (final setup in history) {
          if (setup.outcome != TradeOutcome.open) continue;
          final result = evaluate(setup);
          if (result == null) continue;
          setup.outcome = result.outcome;
          setup.closedPrice = double.parse(result.exitPrice.toStringAsFixed(2));
          setup.closedAt = DateTime.now().toUtc();
          closed.add(setup);
        }
        return closed.isNotEmpty;
      });
    } catch (e) {
      _log('Trade Outcome Watcher: sweep failed: $e');
      return false;
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
  Future<bool> _resolveOpenTrades(List<Candle> m15Raw) =>
      _sweepOpenTrades((setup) => setup.evaluateOutcomeOverCandles(m15Raw));

  /// Sub-second fast path — called by MonitorEngine on every bridge tick. A
  /// BUY closes on the bid, a SELL on the ask.
  Future<bool> resolveOpenTradesAtTick({required double bid, required double ask}) =>
      _sweepOpenTrades((setup) => setup.evaluateOutcomeAtTick(bid: bid, ask: ask));

  bool _cacheValid(int timeframeMinutes, _CachedCandles cached, DateTime now) {
    final ttl = _cacheTtl[timeframeMinutes] ?? Duration.zero;
    if (ttl <= Duration.zero || now.difference(cached.fetchedAt) >= ttl) return false;
    final tfMs = timeframeMinutes * 60000;
    final fetchedBucket = cached.fetchedAt.toUtc().millisecondsSinceEpoch ~/ tfMs;
    final nowBucket = now.toUtc().millisecondsSinceEpoch ~/ tfMs;
    return fetchedBucket == nowBucket;
  }

  Future<_CandleFetch> _getCandles(DataService dataService, int timeframeMinutes, int count) async {
    final now = DateTime.now();
    final cached = _candleCache[timeframeMinutes];
    if (cached != null && _cacheValid(timeframeMinutes, cached, now)) {
      return (candles: cached.candles, isFresh: true, source: cached.source);
    }

    try {
      final fresh = await dataService.getCandles(timeframeMinutes: timeframeMinutes, count: count);
      final source = AppConfig.useMockData ? null : ConnectionStatusService.instance.current;
      if (fresh.isNotEmpty) {
        _candleCache[timeframeMinutes] = _CachedCandles(DateTime.now(), fresh, source);
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
    final dataService = DataService();
    final notes = <String>[];
    _log('--- scan cycle start ---');

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

    final nowUtc = DateTime.now().toUtc();
    final h4 = closedCandlesOnly(h4Fetch.candles, AppConfig.tfH4, nowUtc);
    final h1 = closedCandlesOnly(h1Fetch.candles, AppConfig.tfH1, nowUtc);
    final m15Raw = m15Fetch.candles;
    final m15 = closedCandlesOnly(m15Raw, AppConfig.tfM15, nowUtc);
    final feed = m15Fetch.source;
    final feedLabel = feed?.label ?? 'Mock data';

    final bias = _fourHourBias(h4);
    final hourlyBias = _hourlyBias(h1);

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

    final htfZones = _ta.buildHtfZones(candles15m: m15, candles1h: h1, candles4h: h4);
    final htfNote = 'HTF structure: 4H=${h4.length} 1H=${h1.length}${h1Fetch.isFresh ? "" : "(cached)"} '
        '15M=${m15.length}${m15Fetch.isFresh ? "" : "(cached)"} closed candles | ${htfZones.length} Key Zones';
    final baseInfo = '[$feedLabel] $htfNote';

    if (htfZones.isEmpty) {
      notes.add('$baseInfo | No HTF Key Zones found on 15M/1H/4H yet');
      _log('No HTF zones found near current price \$${livePrice.toStringAsFixed(2)} — '
          '15M/1H/4H structure produced 0 Key Zones this cycle');
      return SignalCheckResult(
        status: 'No new signal — ${notes.join(" | ")} (4H context: ${h4.length} candles, bias: ${_biasLabel(bias)})',
        feed: feed,
        livePrice: livePrice,
      );
    }

    // THREE INDEPENDENT strategies, each with its own debounce state.
    final legacySetup = await _evaluateLegacyTrigger(
      m15: m15,
      htfZones: htfZones,
      bias: bias,
      hourlyBias: hourlyBias,
      baseInfo: baseInfo,
      notes: notes,
      livePrice: livePrice,
    );
    final ictSetup = await _evaluateIctTrigger(
      m15: m15,
      h1: h1,
      h4: h4,
      htfZones: htfZones,
      notes: notes,
      livePrice: livePrice,
    );
    final iciSetup = await _evaluateIciTrigger(
      m15: m15,
      h1: h1,
      h4: h4,
      htfZones: htfZones,
      notes: notes,
      livePrice: livePrice,
    );

    var setups = [
      if (legacySetup != null) legacySetup,
      if (ictSetup != null) ictSetup,
      if (iciSetup != null) iciSetup,
    ];

    // Cross-Strategy Conflict Guard: if strategies disagree on direction,
    // keep only the single highest-Confluence-Score setup.
    if (setups.length > 1 && setups.map((s) => s.direction).toSet().length > 1) {
      final sorted = [...setups]..sort((a, b) => b.confluenceScore.compareTo(a.confluenceScore));
      final kept = sorted.first;
      final dropped = sorted.skip(1).toList();
      final droppedLabel = dropped.map((s) => '${s.setupLabel} (Score ${s.confluenceScore}/100)').join(', ');
      _log('⚠️ Cross-Strategy Conflict — ${setups.length} strategies disagreed on direction this cycle; '
          'keeping the higher score (${kept.setupLabel}, ${kept.confluenceScore}/100) and dropping $droppedLabel');
      notes.add('⚠️ Cross-Strategy Conflict: dropped $droppedLabel — opposed ${kept.setupLabel} '
          '(Score ${kept.confluenceScore}/100), higher score kept');
      setups = [kept];
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
    }

    final summary =
        setups.map((s) => '${s.setupLabel} @ ${s.entry} (Score ${s.confluenceScore}/100)').join(' | ');
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
    required String baseInfo,
    required List<String> notes,
    required double livePrice,
  }) async {
    // 15M is the ONLY execution timeframe (2026-09-14, "completely disable
    // Scalping strategies" — 5M was previously primary with a 1M scalping
    // fallback; both are gone). Reversal/Retest and Momentum/Breakout
    // (TaEngine.findExecutionTrigger) are tried first; Higher Low / Lower
    // High Absorption (TaEngine.find15mAbsorptionTrigger, always 15M-only
    // regardless) is the fallback when that finds nothing.
    ExecutionTrigger? trigger = _ta.findExecutionTrigger(candles: m15, htfZones: htfZones);
    List<Candle> triggerCandles = m15;
    String triggerTimeframeLabel = '15M';

    if (trigger == null) {
      final absorptionTrigger = _ta.find15mAbsorptionTrigger(candles15m: m15, htfZones: htfZones);
      if (absorptionTrigger != null) {
        trigger = absorptionTrigger;
        triggerCandles = m15;
        triggerTimeframeLabel = '15M';
      }
    }

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
    if (lastZoneFire != null && DateTime.now().difference(lastZoneFire) < AppConfig.directionalDebounceWindow) {
      final elapsedMin = DateTime.now().difference(lastZoneFire).inMinutes;
      notes.add(
        '$baseInfo | $triggerInfo | suppressed — zone already signaled ${elapsedMin}m ago '
        '(${AppConfig.directionalDebounceWindow.inMinutes}-min zone cooldown)',
      );
      _log('Setup rejected by Zone Cooldown — $zoneKey already signaled ${elapsedMin}m ago '
          '(${AppConfig.directionalDebounceWindow.inMinutes}-min cooldown)');
      return null;
    }

    final zone = SetupZone(type: trigger.type, zonePrice: trigger.zone.price, candleIndex: trigger.candleIndex);
    final setup = _risk.buildTradeSetup(
      candles: triggerCandles,
      zone: zone,
      pattern: trigger.pattern,
      timeframeLabel: triggerTimeframeLabel,
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
      notes.add('$baseInfo | $triggerInfo | Setup rejected: TP distance below ${AppConfig.minTakeProfitPips.toStringAsFixed(0)} pips minimum');
      return null;
    }

    if (_rejectsMinStopLossDistance(setup)) {
      notes.add('$baseInfo | $triggerInfo | Setup rejected: SL distance below ${AppConfig.minStopLossPips.toStringAsFixed(0)} pips minimum');
      return null;
    }

    // HTF Trend Alignment Gate (2026-09-10, revised twice — checks BOTH 1H
    // and 4H bias, applies to EVERY setup, not just 1M scalps): a setup
    // opposing a CLEAR 1H OR 4H macro bias is rejected outright, UNLESS
    // it's either —
    //  a) a genuine Break & Retest (SetupType.htfRetest) — price already
    //     broke through the structural zone and came back to confirm it,
    //     which earns the right to trade against the immediate trend, or
    //  b) anchored directly to a larger-timeframe (1H) HTF zone
    //     (trigger.zone.source mentions "1H") — direct contact with a
    //     bigger structural level is its own justification regardless of
    //     the bias — EXCEPT for 15M Absorption (SetupType.absorption15m),
    //     which never gets this exemption: 3/3 countertrend 15M Absorption
    //     BUYs fired through this exact loophole on 2026-09-10 (each one
    //     against a persistent bearish 1H/4H move) and every single one
    //     lost. Absorption is now hard-gated by trend with NO exemption
    //     other than a genuine Break & Retest, which it structurally can
    //     never be (its own SetupType is always absorption15m, never
    //     htfRetest) — so in practice a countertrend 15M Absorption can
    //     never fire anymore.
    // Checking 1H too (not just 4H) catches a setup that agrees with the
    // slower 4H trend but is actually fighting the more immediate 1H move.
    // A neutral/unclear bias on either timeframe never blocks on its own —
    // only a CLEAR, opposing bias does.
    final isBreakRetest = trigger.type == SetupType.htfRetest;
    final isAbsorption15m = trigger.type == SetupType.absorption15m;
    final isAtLargerTimeframeZone = !isAbsorption15m && trigger.zone.source.contains('1H');
    final opposes4hBias = bias != null && setup.direction != bias;
    final opposes1hBias = hourlyBias != null && setup.direction != hourlyBias;
    if ((opposes4hBias || opposes1hBias) && !isBreakRetest && !isAtLargerTimeframeZone) {
      notes.add(
        '$baseInfo | $triggerInfo | Setup rejected: opposes macro bias '
        '(1H: ${_biasLabel(hourlyBias)}, 4H: ${_biasLabel(bias)})',
      );
      _log('Setup rejected by HTF Trend Alignment — opposes macro bias '
          '(1H: ${_biasLabel(hourlyBias)}, 4H: ${_biasLabel(bias)}), '
          'and is neither a Break & Retest nor (for non-Absorption setups) anchored to a '
          'larger-timeframe (1H) zone');
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
        DateTime.now().difference(_lastSignalDirectionTime!) < AppConfig.directionalDebounceWindow;
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

    // All rules passed — fire.
    _lastSignalCandleTime = candleTime;
    _lastSignalDirection = setup.direction;
    _lastSignalDirectionTime = DateTime.now();
    _lastZoneSignalTime[zoneKey] = DateTime.now();

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
    final found = _ict.findTrigger(candles15m: m15, candles1h: h1, candles4h: h4, htfZones: htfZones);
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
    if (lastZoneFire != null && DateTime.now().difference(lastZoneFire) < AppConfig.directionalDebounceWindow) {
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
      notes.add('[ICT] $triggerInfo | rejected: TP distance below ${AppConfig.minTakeProfitPips.toStringAsFixed(0)} pips minimum');
      return null;
    }

    if (_rejectsMinStopLossDistance(setup)) {
      notes.add('[ICT] $triggerInfo | rejected: SL distance below ${AppConfig.minStopLossPips.toStringAsFixed(0)} pips minimum');
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

    final inSession = _ict.isHighLiquiditySession(DateTime.now().toUtc());
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
        DateTime.now().difference(_lastIctSignalDirectionTime!) < AppConfig.directionalDebounceWindow;
    if (withinWindow && setup.direction != _lastIctSignalDirection) {
      notes.add('[ICT] $triggerInfo | Score $score/100 | suppressed — opposes the last ICT signal within the '
          '${AppConfig.directionalDebounceWindow.inMinutes}-min debounce window');
      return null;
    }

    _lastIctSignalCandleTime = candleTime;
    _lastIctSignalDirection = setup.direction;
    _lastIctSignalDirectionTime = DateTime.now();
    _lastIctZoneSignalTime[zoneKey] = DateTime.now();

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

    if (setup.riskRewardRatio >= AppConfig.riskRewardRatio) score += 25;

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
    if (lastZoneFire != null && DateTime.now().difference(lastZoneFire) < AppConfig.directionalDebounceWindow) {
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
    );
    if (setup == null) {
      notes.add('[ICI] $triggerInfo | rejected: invalid risk distance (Entry == Stop Loss)');
      return null;
    }

    // Stop-Loss Safety Floor (2026-09-13, ICI-ONLY — explicit request):
    // widen SL to at least AppConfig.iciMinStopLossDollars and reprice TP
    // to hold the 1:2 ratio. RiskEngine itself stays floor-free for the
    // legacy and ICT strategies; TradeSetup's fields are final, so a
    // floored setup is a fresh instance rather than a mutation.
    //
    // Widened to the LARGER of the ICI-specific $1.50 floor and the
    // blanket AppConfig.minStopLossPips floor added 2026-09-14 (currently
    // 20 pips = $2.00, stricter than $1.50) — otherwise this would widen
    // a tight SL to exactly $1.50 only for _rejectsMinStopLossDistance
    // right below to immediately reject it anyway for still being under
    // 20 pips, making the widening pointless for exactly the setups that
    // needed it.
    final effectiveMinRisk = max(AppConfig.iciMinStopLossDollars, AppConfig.minStopLossPips * TradeSetup.dollarsPerPip);
    if (setup.riskDollars < effectiveMinRisk) {
      final widenedRisk = effectiveMinRisk;
      final newStopLoss = setup.direction == TradeDirection.buy ? setup.entry - widenedRisk : setup.entry + widenedRisk;
      final newTakeProfit = setup.direction == TradeDirection.buy
          ? setup.entry + AppConfig.riskRewardRatio * widenedRisk
          : setup.entry - AppConfig.riskRewardRatio * widenedRisk;
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
      notes.add('[ICI] $triggerInfo | rejected: TP distance below ${AppConfig.minTakeProfitPips.toStringAsFixed(0)} pips minimum');
      return null;
    }

    if (_rejectsMinStopLossDistance(setup)) {
      notes.add('[ICI] $triggerInfo | rejected: SL distance below ${AppConfig.minStopLossPips.toStringAsFixed(0)} pips minimum');
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
      notes.add('[ICI] $triggerInfo | Confluence Score $score/100 — rejected (< ${AppConfig.minConfluenceScoreIci} required)');
      return null;
    }

    final withinWindow = _lastIciSignalDirection != null &&
        _lastIciSignalDirectionTime != null &&
        DateTime.now().difference(_lastIciSignalDirectionTime!) < AppConfig.directionalDebounceWindow;
    if (withinWindow && setup.direction != _lastIciSignalDirection) {
      notes.add('[ICI] $triggerInfo | Score $score/100 | suppressed — opposes the last ICI signal within the '
          '${AppConfig.directionalDebounceWindow.inMinutes}-min debounce window');
      return null;
    }

    _lastIciSignalCandleTime = candleTime;
    _lastIciSignalDirection = setup.direction;
    _lastIciSignalDirectionTime = DateTime.now();
    _lastIciZoneSignalTime[zoneKey] = DateTime.now();

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

    if (setup.riskRewardRatio >= AppConfig.riskRewardRatio) score += 25;

    final signalCount = ' + '.allMatches(zoneSource).length + 1;
    score += signalCount >= 2 ? 25 : 15;

    return score;
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
    if (setup.riskRewardRatio >= AppConfig.riskRewardRatio) score += 25;

    // Structural SL integrity (25): there's no minimum-SL floor/clamp
    // anymore (2026-09-10 — the user sizes their own lot to the real pip
    // distance instead), so every setup's SL is always the organic
    // structural distance — full credit every time.
    score += 25;

    return score;
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
