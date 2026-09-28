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
import 'dxy_filter_service.dart';
import 'ict_engine.dart';
import 'impulse_correction_engine.dart';
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
  final RiskEngine _risk;

  /// Injectable clock and data source (2026-09-25) — both default to the
  /// real ones, so the app behaves exactly as before. They exist so the
  /// REAL [check] pipeline can be replayed over historical candles (see
  /// test/_backtest_all.dart) instead of a re-implementation that could
  /// drift from it: every debounce, cooldown, session filter and outcome
  /// sweep below reads [_now] rather than the wall clock.
  final DateTime Function() _now;
  final DataService Function() _newDataService;

  SignalChecker({DataService Function()? dataServiceFactory, DateTime Function()? clock})
      : _now = clock ?? DateTime.now,
        _newDataService = dataServiceFactory ?? DataService.new,
        _risk = RiskEngine(clock: clock);
  final AiEngine _ai = AiEngine();
  final NotifierService _notifier = NotifierService();
  final PriceAlertService _alerts = PriceAlertService();
  final NewsCalendarService _newsCalendar = NewsCalendarService();
  final DxyFilterService _dxy = DxyFilterService();
  final Mt5TradingService _trading = Mt5TradingService();

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

  /// Prints the reasoning behind every accept/reject decision this cycle
  /// makes, routed through AppLogger (persisted, visible in System Logs from
  /// either isolate, and in `adb logcat`).
  void _log(String message) => AppLogger.log(message);

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
  Future<bool> _passesDxyFilter(TradeSetup setup, String triggerInfo, List<String> notes) async {
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
  /// the highest-ranked engine here survives — lower index wins. Fixed
  /// hierarchy per the request: Top-Down > ICT > ORB (Retest) > ICI >
  /// Breakout/Momentum — deliberately NOT alphabetical/declaration order
  /// (ORB outranks ICI here even though ICI is the older strategy).
  static const List<StrategyFamily> _enginePriorityOrder = [
    StrategyFamily.topDown,
    StrategyFamily.ict,
    StrategyFamily.orb,
    StrategyFamily.ici,
    StrategyFamily.breakout,
    // Ranging Market Module, last (2026-09-25). It can only fire while
    // there is NO clear HTF bias, which is precisely when the five
    // trend-following engines above are least likely to have fired at all,
    // so this ranking rarely decides anything — but it must be PRESENT:
    // _enginePriorityRank uses indexOf, and a family missing from this list
    // would rank -1 and silently outrank every other engine.
    StrategyFamily.rangingBounce,
  ];

  int _enginePriorityRank(TradeSetup setup) => _enginePriorityOrder.indexOf(setup.setupType.strategyFamily);

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
  Future<bool> _resolveOpenTrades(List<Candle> m15Raw) => _sweepOpenTrades(
      (setup) => setup.evaluateOutcomeOverCandles(m15Raw, updateBreakEven: AppConfig.breakEvenEnabled));

  /// Sub-second fast path — called by MonitorEngine on every bridge tick. A
  /// BUY closes on the bid, a SELL on the ask.
  Future<bool> resolveOpenTradesAtTick({required double bid, required double ask}) => _sweepOpenTrades(
      (setup) => setup.evaluateOutcomeAtTick(bid: bid, ask: ask, updateBreakEven: AppConfig.breakEvenEnabled));

  /// Manual Close (2026-09-17, explicit request): closes the OPEN trade
  /// identified by [tradeId] (TradeSetup.uid) at [currentPrice] — pips are
  /// computed the normal way (relative to Entry) and the outcome is
  /// persisted as [TradeOutcome.manualClose] rather than win/loss. Returns
  /// true if a matching open trade was found and closed, false otherwise
  /// (already closed / unknown id).
  Future<bool> closeTradeManually(String tradeId, double currentPrice) async {
    TradeSetup? closedSetup;
    await HistoryStore.mutate((history) {
      for (final setup in history) {
        if (setup.uid != tradeId) continue;
        if (setup.closeTradeManually(currentPrice)) closedSetup = setup;
        break;
      }
      return closedSetup != null;
    });
    if (closedSetup == null) {
      _log('Manual Close requested for unknown/already-closed trade id: $tradeId');
      return false;
    }
    final setup = closedSetup!;
    _log('✋ Manually Closed — ${setup.setupLabel} closed @ \$${setup.closedPrice!.toStringAsFixed(2)} '
        '(${setup.pips! >= 0 ? "+" : ""}${setup.pips!.toStringAsFixed(1)} pips)');
    await _notifier.sendOutcome(setup);
    return true;
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
    final m5Fetch = needsM5 ? await _getCandles(dataService, AppConfig.tfM5, 200) : null;

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

    // One Active Trade Limit (2026-09-17, explicit request): while any
    // trade is still open, no new signal is generated at all — strategy
    // evaluation is skipped entirely until the current trade closes
    // (win, loss, or manual close).
    final openTrades = (await HistoryStore.load()).where((s) => s.outcome == TradeOutcome.open).toList();
    if (AppConfig.oneActiveTradeLimit && openTrades.isNotEmpty) {
      final open = openTrades.first;
      notes.add('$feedLabel | One Active Trade Limit: ${open.setupLabel} @ ${open.entry} still open — '
          'new signal generation paused until it closes');
      _log('One Active Trade Limit: ${open.setupLabel} @ ${open.entry} still open — skipping signal generation this cycle');
      return SignalCheckResult(
        status: 'No new signal — ${notes.join(" | ")} (4H context: ${h4.length} candles, bias: ${_biasLabel(bias)})',
        feed: feed,
        livePrice: livePrice,
      );
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
      legacySetup = await _evaluateLegacyTrigger(
        m15: m15,
        htfZones: htfZones,
        bias: bias,
        hourlyBias: hourlyBias,
        htfStructureBias: htfStructureBias,
        baseInfo: baseInfo,
        notes: notes,
        livePrice: livePrice,
      );
      ictSetup = await _evaluateIctTrigger(
        m15: m15,
        h1: h1,
        h4: h4,
        htfZones: htfZones,
        notes: notes,
        livePrice: livePrice,
      );
      iciSetup = await _evaluateIciTrigger(
        m15: m15,
        h1: h1,
        h4: h4,
        htfZones: htfZones,
        notes: notes,
        livePrice: livePrice,
      );
    }

    // A FOURTH, fully independent strategy tier (2026-09-18) — never reads
    // htfZones, an HTF bias, or any candlestick pattern; see orb_engine.dart.
    final orbSetup = AppConfig.useOrb
        ? await _evaluateOrbTrigger(candles5m: m5, nowUtc: nowUtc, notes: notes, livePrice: livePrice)
        : null;

    // A FIFTH, fully independent strategy tier (2026-09-18, rebuilt
    // 2026-09-22): HTF zones are only ONE of its five level sources now
    // (Previous Day, session, swing and Opening Range levels don't need
    // them), so it still runs with an empty zone pool; see
    // breakout_momentum_engine.dart.
    final breakoutSetup = AppConfig.useBreakoutMomentum
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
    final zoneBounceSetup = AppConfig.enableRangingBounceMode && htfZones.isNotEmpty
        ? await _evaluateZoneBounceTrigger(
            m15: m15,
            htfZones: htfZones,
            htfStructureBias: htfStructureBias,
            notes: notes,
            livePrice: livePrice,
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

    final liveTradingReady = !AppConfig.useMockData && !AppConfig.disableMt5Bridge;
    final winner = setups.single;

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
      if (spreadPips != null && spreadPips > AppConfig.maxSpreadPips) {
        final message = 'Signal rejected: Live spread (${spreadPips.toStringAsFixed(1)} pips) exceeds maximum '
            'allowed (${AppConfig.maxSpreadPips.toStringAsFixed(0)} pips).';
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
        final lot = _risk.calculateLotSize(equity: account.equity, stopLossDollars: winner.riskDollars);
        winner.lotSize = lot;
        final order = await _trading.openMarketOrder(
          direction: winner.direction,
          volume: lot,
          stopLoss: winner.stopLoss,
          takeProfit: winner.takeProfit,
        );
        if (order.success) {
          winner.brokerTicket = order.ticket;
          // The REAL fill price (2026-09-21, explicit fix): a market order
          // can slip a little from the theoretical [entry] priced off the
          // confirmation candle's close — every later money calculation
          // must use this, not entry, so Break-Even/live P&L exactly match
          // what the broker actually did (see TradeSetup.effectiveEntry).
          winner.actualFillPrice = order.price;
          _log('🏦 Auto-Trading — ${winner.directionLabel} order #${order.ticket} opened @ '
              '\$${order.price?.toStringAsFixed(2)} for $lot lots (Risk ${AppConfig.riskPercentPerTrade.toStringAsFixed(1)}% '
              'of \$${account.equity.toStringAsFixed(2)} equity)');
        } else {
          _log('⚠️ Auto-Trading — broker rejected the ${winner.directionLabel} order: ${order.error}. '
              '${winner.setupLabel} still recorded as a signal-only alert.');
        }
      }
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

    if (_rejectsMaxStopLossDistance(setup)) {
      notes.add('$baseInfo | $triggerInfo | Setup rejected: SL distance above ${AppConfig.maxStopLossPips.toStringAsFixed(0)} pips maximum');
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

    if (!await _passesDxyFilter(setup, '$baseInfo | $triggerInfo', notes)) return null;

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

    if (_rejectsMaxStopLossDistance(setup)) {
      notes.add('[ICT] $triggerInfo | rejected: SL distance above ${AppConfig.maxStopLossPips.toStringAsFixed(0)} pips maximum');
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

    if (!await _passesDxyFilter(setup, '[ICT] $triggerInfo', notes)) return null;

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
          ? setup.entry + AppConfig.riskRewardRatio * widenedRisk
          : setup.entry - AppConfig.riskRewardRatio * widenedRisk;
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
      notes.add('[ICI] $triggerInfo | rejected: TP distance below ${AppConfig.minTakeProfitPips.toStringAsFixed(0)} pips minimum');
      return null;
    }

    if (_rejectsMinStopLossDistance(setup)) {
      notes.add('[ICI] $triggerInfo | rejected: SL distance below ${AppConfig.minStopLossPips.toStringAsFixed(0)} pips minimum');
      return null;
    }

    if (_rejectsMaxStopLossDistance(setup)) {
      notes.add('[ICI] $triggerInfo | rejected: SL distance above ${AppConfig.maxStopLossPips.toStringAsFixed(0)} pips maximum');
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
        _now().difference(_lastIciSignalDirectionTime!) < AppConfig.directionalDebounceWindow;
    if (withinWindow && setup.direction != _lastIciSignalDirection) {
      notes.add('[ICI] $triggerInfo | Score $score/100 | suppressed — opposes the last ICI signal within the '
          '${AppConfig.directionalDebounceWindow.inMinutes}-min debounce window');
      return null;
    }

    if (!await _passesDxyFilter(setup, '[ICI] $triggerInfo', notes)) return null;

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

    if (setup.riskRewardRatio >= AppConfig.riskRewardRatio) score += 25;

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
  }) async {
    if (htfStructureBias != null) {
      notes.add('[Range] Clear HTF bias (${htfStructureBias.name}) — ranging module stands down');
      return null;
    }

    final trigger = _zoneBounce.findTrigger(
      candles: m15,
      zones: htfZones,
      htfBias: htfStructureBias,
    );
    if (trigger == null) {
      notes.add('[Range] No clean rejection at the '
          '${AppConfig.zoneBounceEvaluatedZoneCount} nearest Key Zones this cycle');
      return null;
    }

    final candleTime = trigger.rejectionCandle.time;
    if (_lastZoneBounceSignalCandleTime == candleTime) return null;

    final zoneKey = trigger.zone.price.toStringAsFixed(2);
    final lastZoneFire = _lastZoneBounceZoneSignalTime[zoneKey];
    if (lastZoneFire != null &&
        _now().difference(lastZoneFire) < AppConfig.directionalDebounceWindow) {
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

    final withinWindow = _lastZoneBounceSignalDirection != null &&
        _lastZoneBounceSignalDirectionTime != null &&
        _now().difference(_lastZoneBounceSignalDirectionTime!) <
            AppConfig.directionalDebounceWindow;
    if (withinWindow && setup.direction != _lastZoneBounceSignalDirection) {
      notes.add('[Range] $triggerInfo | Score $score/100 | suppressed — opposes the last '
          'Range Bounce signal within the '
          '${AppConfig.directionalDebounceWindow.inMinutes}-min debounce window');
      return null;
    }

    // No DXY gate here by design — see this method's doc comment.

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

    // Zone timeframe (10-30): a 4H level is structurally heavier than a 15M
    // one. Same instinct as findNearestZone's handicap, but expressed where
    // it belongs — in the SCORE, where it informs the decision instead of
    // silently hiding a closer level from evaluation entirely.
    score += trigger.zone.source.startsWith('4H')
        ? 30
        : trigger.zone.source.startsWith('1H')
            ? 22
            : 10;

    // How cleanly the wick tested the level (0-20): a wick driven decisively
    // INTO the level and thrown back is a stronger test than a graze.
    final penetration = (trigger.isBuy
            ? trigger.zone.price - trigger.rejectionExtreme
            : trigger.rejectionExtreme - trigger.zone.price)
        .clamp(0.0, double.infinity);
    score += (penetration / AppConfig.zoneBounceTouchDollars * 20).clamp(0.0, 20.0).round();

    // Room to the range's far side (0-20): the share of the full configured
    // target this setup can reach before running into the opposing boundary.
    final ratioShare = (setup.riskRewardRatio / AppConfig.riskRewardRatio).clamp(0.0, 1.0);
    score += (ratioShare * 20).round();

    return score.clamp(0, 100);
  }

  /// The Opening Range Breakout strategy tier (see orb_engine.dart) — the
  /// ONLY tier that never reads htfZones, an HTF bias, or a candlestick
  /// pattern; its own [OrbRange.key]-based "Single Trade per Range" state
  /// ([_consumedOrbRanges]) plays the role every other tier's candle/zone
  /// debounce does — set ONLY once a trigger actually fires (survives every
  /// gate below), never merely because one was found, so a candidate
  /// rejected this cycle (e.g. score too low, DXY opposed) stays eligible
  /// for a later cycle rather than burning the range's one shot for nothing.
  /// Tries each AppConfig-enabled session in declaration order (London
  /// before New York) and returns the first that fires; a session whose
  /// range hasn't formed yet, is already consumed, or has no trigger this
  /// cycle simply falls through to the next.
  Future<TradeSetup?> _evaluateOrbTrigger({
    required List<Candle> candles5m,
    required DateTime nowUtc,
    required List<String> notes,
    required double livePrice,
  }) async {
    if (candles5m.isEmpty) {
      notes.add('[ORB] Waiting on 5M candles');
      return null;
    }

    for (final session in OrbSession.values) {
      if (!session.enabled) continue;

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
            '— expired (${AppConfig.orbMaxHoursAfterRange}h window closed), no trade today');
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

      final score = _orbConfluenceScore(setup);
      setup.confluenceScore = score;
      if (score < AppConfig.minConfluenceScoreOrb) {
        notes.add('[ORB] $triggerInfo | Confluence Score $score/100 — rejected '
            '(< ${AppConfig.minConfluenceScoreOrb} required)');
        continue;
      }

      if (!await _passesDxyFilter(setup, '[ORB] $triggerInfo', notes)) continue;

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
  /// [AppConfig.slBufferDollars], and TP holds the standard
  /// [AppConfig.riskRewardRatio]; either side switches to a fixed pip
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
    final takeProfit = tpPips > 0
        ? (bullish ? entry + tpPips * TradeSetup.dollarsPerPip : entry - tpPips * TradeSetup.dollarsPerPip)
        : (bullish ? entry + AppConfig.riskRewardRatio * riskDistance : entry - AppConfig.riskRewardRatio * riskDistance);

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

  /// ORB's own Confluence Score (0-100) — no HTF-bias-alignment component
  /// at all (ORB deliberately has no bias input to score against), so
  /// weight instead falls on the mechanical break itself and what it pays.
  /// A retest is now mandatory for every ORB trigger (2026-09-18, the
  /// immediate no-retest entry mode was removed), so the retest-confirmed
  /// bonus is no longer conditional — every fired setup already earns it.
  int _orbConfluenceScore(TradeSetup setup) {
    var score = 30; // base: a clean mechanical break of a defined session range is inherently structural
    score += 45; // every fired ORB setup is now a confirmed retest, materially stronger than a raw breakout
    if (setup.riskRewardRatio >= AppConfig.riskRewardRatio) score += 25;
    return score;
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
    final dxyMode = AppConfig.breakoutDxyMode;
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
      final event = await _newsCalendar.blackoutEvent(blackout);
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
