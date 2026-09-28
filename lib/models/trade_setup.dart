import 'candle.dart';
import 'pivot.dart';

/// The final, fully-priced trade signal produced by Aureus AI,
/// ready to be shown in the UI and pushed to Telegram.
class TradeSetup {
  final String symbol;
  final TradeDirection direction;
  final String timeframeLabel;
  final SetupType setupType;
  final double entry;
  final double stopLoss;
  final double takeProfit;
  final CandlePattern pattern;
  final DateTime detectedAt;

  /// Rule 1 diagnostic: true if RiskEngine had to widen the SL to the
  /// $5.00 minimum guard (the raw HTF-zone/wick distance was tighter) —
  /// used by the Confluence Score as a sign of a less "clean" structural
  /// stop, not just whether the guard was respected (it always is).
  final bool slWasClamped;

  /// 0-100 Confluence Score (HTF trend alignment + reversal-pattern
  /// strength + R:R + organic-vs-clamped SL) — set by SignalChecker right
  /// after the setup is priced, before the >=70 filter decides whether it
  /// ever gets emitted. Kept on the setup so the UI can show *why* a fired
  /// signal was considered high-probability, not just that it was.
  int confluenceScore;

  String aiReason; // filled in asynchronously by AiEngine

  /// Live-tracked by SignalChecker's per-cycle sweep (see
  /// [evaluateOutcome]) — [TradeOutcome.open] until the live price
  /// crosses [stopLoss] or [takeProfit], then locked permanently.
  TradeOutcome outcome;
  double? closedPrice;
  DateTime? closedAt;

  /// Break-Even state (2026-09-17, RETIRED 2026-09-24 — see
  /// AppConfig.breakEvenEnabled, now false): flipped to true the moment
  /// price reached 1:1 Risk:Reward in this trade's favour, after which the
  /// effective Stop Loss became the Entry price itself ([activeStopLoss])
  /// instead of the original structural [stopLoss]; the Take Profit was
  /// never touched and stayed at the configured R:R.
  ///
  /// Nothing arms this on a NEW trade any more — SignalChecker's outcome
  /// sweeps pass updateBreakEven: AppConfig.breakEvenEnabled, so the Stop
  /// Loss stays where it was placed for the life of the trade. The field,
  /// [breakEvenTriggerPrice] and [activeStopLoss] all remain so trades
  /// closed at Break-Even BEFORE that change still load and render their
  /// real outcome, and so the behaviour can be switched back on from .env
  /// without a code change.
  /// Persisted so the state survives isolate/app restarts.
  bool breakEvenActive;

  /// Which feed the setup was priced from (e.g. "MT5 Bridge", "TwelveData
  /// XAU/USD") — null for setups persisted before this field existed.
  String? dataSource;

  /// Dynamic Position Sizing (Institutional Risk Management, 2026-09-20):
  /// the lot size RiskEngine.calculateLotSize computed off live account
  /// Balance/Equity and [AppConfig.riskPercentPerTrade] at the moment this
  /// setup fired. Null when auto-trading is off or the account snapshot
  /// couldn't be fetched — the setup is still shown/tracked, just never
  /// sized/executed.
  double? lotSize;

  /// The REAL MT5 position ticket this setup was opened as (see
  /// Mt5TradingService.openMarketOrder) — null for a setup that was only
  /// ever a local/virtual signal (mock mode, auto-trading off, or the
  /// broker rejected the order).
  int? brokerTicket;

  /// The broker's ACTUAL fill price for [brokerTicket] (2026-09-21,
  /// discovered live: a market order can slip a little between the moment
  /// [entry] is priced off the confirmation candle's close and the moment
  /// the broker actually fills it — a real position's Break-Even level had
  /// drifted from what the app tracked locally because it moved the REAL
  /// Stop Loss to the THEORETICAL [entry] instead of this). See
  /// [effectiveEntry] — every money calculation (Break-Even trigger, live
  /// floating P/L, realized pips) uses this instead of [entry] once it's
  /// set, so the app's own numbers always match what the broker actually
  /// did. Null for a signal-only setup, or one whose broker order
  /// failed/was never attempted.
  double? actualFillPrice;

  /// The price actually used for every money calculation — see
  /// [actualFillPrice]'s own doc comment for why this differs from the
  /// theoretical, signal-only [entry] for a broker-filled trade.
  double get effectiveEntry => actualFillPrice ?? entry;

  /// HISTORICAL ONLY (2026-09-20 to 2026-09-21) — Automatic Partial
  /// Take-Profit: true for a trade whose REAL position really did have 50%
  /// closed at 1:1 R:R before the Break-Even sync. Removed 2026-09-21,
  /// explicit request ("بدون قفل جزئي، بس تحريك الستوب للدخول عند 1R") —
  /// no NEW trade ever sets this again (see [breakEvenSynced] for the
  /// current, partial-close-free guard). Kept only so a trade that really
  /// did partial-close before the change still reports its correct
  /// blended P&L (see [_realizedDelta]) instead of silently losing the
  /// profit that portion actually banked.
  bool partialTpExecuted;

  /// HISTORICAL ONLY — see [partialTpExecuted]. The ACTUAL price that
  /// trade's 50% was closed at (the broker's own fill, not the theoretical
  /// [breakEvenTriggerPrice]). Null for a setup that never triggered
  /// [partialTpExecuted], or one persisted before this field existed (see
  /// [_realizedDelta]'s fallback to [breakEvenTriggerPrice]).
  double? partialClosePrice;

  /// Break-Even Broker Sync guard (2026-09-21): true once the REAL
  /// position's Stop Loss has actually been moved to Entry for
  /// [brokerTicket] — guards against retrying it every subsequent cycle
  /// once [breakEvenActive] flips true. The current, simplified sync: no
  /// partial close, just the SL move — see [partialTpExecuted] for the
  /// retired partial-close guard this replaced.
  bool breakEvenSynced;

  TradeSetup({
    required this.symbol,
    required this.direction,
    required this.timeframeLabel,
    required this.setupType,
    required this.entry,
    required this.stopLoss,
    required this.takeProfit,
    required this.pattern,
    required this.detectedAt,
    this.slWasClamped = false,
    this.confluenceScore = 0,
    this.aiReason = 'Generating AI analysis…',
    this.outcome = TradeOutcome.open,
    this.closedPrice,
    this.closedAt,
    this.breakEvenActive = false,
    this.dataSource,
    this.lotSize,
    this.brokerTicket,
    this.actualFillPrice,
    this.partialTpExecuted = false,
    this.partialClosePrice,
    this.breakEvenSynced = false,
  });

  /// Price at which the trade is 1R in profit — the Break-Even trigger.
  /// Measured from [effectiveEntry] (the REAL broker fill once known), not
  /// the theoretical [entry] — see [actualFillPrice]'s doc comment.
  double get breakEvenTriggerPrice => direction == TradeDirection.buy
      ? effectiveEntry + riskDollars
      : effectiveEntry - riskDollars;

  /// The Stop Loss actually in force right now: [effectiveEntry] once
  /// Break-Even has been triggered, otherwise the original structural
  /// Stop Loss.
  double get activeStopLoss => breakEvenActive ? effectiveEntry : stopLoss;

  /// Persisted signal history lives under this SharedPreferences key —
  /// the single source of truth both SignalMonitor (UI display) and
  /// SignalChecker's outcome-tracking sweep (see signal_checker.dart,
  /// runs in BOTH the foreground-service and manual-scan isolates) read
  /// and write, so a trade closed by either isolate is reflected
  /// everywhere. Centralized here instead of duplicated as a private
  /// constant in each file, to rule out the two copies ever drifting.
  static const historyPrefsKey = 'aureus_signal_history_v1';

  /// Checks a full [candle]'s HIGH/LOW against this setup's SL/TP —
  /// returns the outcome the moment either is touched INTRABAR, or null
  /// while still open. Deliberately checks the candle's extremes rather
  /// than just its close (2026-09-14 fix): a candle that wicks through
  /// SL and recovers before it closes is a real stop-out a live broker
  /// would have filled, and checking only `.close` would miss it (or
  /// wrongly report a win/loss later, off a candle that never actually
  /// touched either level intrabar). [exitPrice] is the exact SL/TP
  /// level itself — the realistic fill price at that boundary — not
  /// whatever the candle's own high/low happened to overshoot to. SL and
  /// TP sit on opposite sides of Entry by construction, so a single
  /// candle can only legitimately satisfy both on an extreme range bar;
  /// SL is checked first purely as a conservative tie-break.
  /// [updateBreakEven] lets the caller (the outcome sweep) also ARM
  /// Break-Even off this candle: SL is checked first (conservative
  /// tie-break), then 1R is checked to flip [breakEvenActive], so a single
  /// candle that runs to 1R and back only ever stops out at Entry, never
  /// at the original SL. Callers that merely *peek* at the state leave it
  /// false so nothing is mutated.
  ({TradeOutcome outcome, double exitPrice})? evaluateOutcome(Candle candle, {bool updateBreakEven = false}) {
    final sl = activeStopLoss;
    if (direction == TradeDirection.buy) {
      if (candle.low <= sl) return (outcome: TradeOutcome.loss, exitPrice: sl);
      if (updateBreakEven && !breakEvenActive && candle.high >= breakEvenTriggerPrice) {
        breakEvenActive = true;
      }
      if (candle.high >= takeProfit) return (outcome: TradeOutcome.win, exitPrice: takeProfit);
      if (breakEvenActive && candle.low <= effectiveEntry) {
        return (outcome: TradeOutcome.loss, exitPrice: effectiveEntry);
      }
    } else {
      if (candle.high >= sl) return (outcome: TradeOutcome.loss, exitPrice: sl);
      if (updateBreakEven && !breakEvenActive && candle.low <= breakEvenTriggerPrice) {
        breakEvenActive = true;
      }
      if (candle.low <= takeProfit) return (outcome: TradeOutcome.win, exitPrice: takeProfit);
      if (breakEvenActive && candle.high >= effectiveEntry) {
        return (outcome: TradeOutcome.loss, exitPrice: effectiveEntry);
      }
    }
    return null;
  }

  /// Walks [candles] (chronological) and returns the FIRST one that touches
  /// SL or TP — but only candles that opened at or after this setup's own
  /// entry candle closed, so a wick that happened BEFORE the trade existed
  /// can never close it. [grace] tolerates the few seconds between a candle
  /// boundary and the scan that priced the setup off the just-closed candle.
  ({TradeOutcome outcome, double exitPrice})? evaluateOutcomeOverCandles(
    List<Candle> candles, {
    Duration grace = const Duration(minutes: 2),
    bool updateBreakEven = false,
  }) {
    final earliest = detectedAt.toUtc().subtract(grace);
    for (final candle in candles) {
      if (candle.time.isBefore(earliest)) continue;
      final result = evaluateOutcome(candle, updateBreakEven: updateBreakEven);
      if (result != null) return result;
    }
    return null;
  }

  /// Live TICK check. A BUY position closes on the BID, a SELL position
  /// closes on the ASK — using the bid for both would stop SELLs out late
  /// and hand them TP early by the whole spread. [exitPrice] is the actual
  /// tick price (realistic fill, including slippage past the level).
  ({TradeOutcome outcome, double exitPrice})? evaluateOutcomeAtTick({
    required double bid,
    required double ask,
    bool updateBreakEven = false,
  }) {
    final sl = activeStopLoss;
    if (direction == TradeDirection.buy) {
      if (bid <= sl) return (outcome: TradeOutcome.loss, exitPrice: bid);
      if (updateBreakEven && !breakEvenActive && bid >= breakEvenTriggerPrice) {
        breakEvenActive = true;
      }
      if (bid >= takeProfit) return (outcome: TradeOutcome.win, exitPrice: bid);
    } else {
      if (ask >= sl) return (outcome: TradeOutcome.loss, exitPrice: ask);
      if (updateBreakEven && !breakEvenActive && ask <= breakEvenTriggerPrice) {
        breakEvenActive = true;
      }
      if (ask <= takeProfit) return (outcome: TradeOutcome.win, exitPrice: ask);
    }
    return null;
  }

  /// Manually closes an OPEN trade on demand (2026-09-17, explicit
  /// request): prices it at [currentPrice], computes pips the exact same
  /// way [pips] normally does off [closedPrice], and marks the outcome
  /// [TradeOutcome.manualClose] instead of the usual win/loss. No-op
  /// (returns false) if the trade is already closed. Callers are
  /// responsible for persisting the mutated setup (see
  /// SignalChecker.closeTradeManually, which does this via HistoryStore).
  bool closeTradeManually(double currentPrice) {
    if (outcome != TradeOutcome.open) return false;
    outcome = TradeOutcome.manualClose;
    closedPrice = double.parse(currentPrice.toStringAsFixed(2));
    closedAt = DateTime.now().toUtc();
    return true;
  }

  /// Stable id for this setup (history de-duplication + notification ids).
  String get uid => '${setupType.name}|$directionLabel|${entry.toStringAsFixed(2)}|${detectedAt.toUtc().millisecondsSinceEpoch}';

  /// Positive 31-bit notification id derived from [uid], so two setups fired
  /// in the same second no longer overwrite each other's notification.
  int notificationId({int salt = 0}) => ('$uid#$salt'.hashCode & 0x3fffffff);

  /// True when [other] is the same trade idea (same strategy type,
  /// direction and entry) fired within [window] — used to drop duplicates
  /// re-emitted after an isolate/service restart reset debounce state.
  bool isDuplicateOf(TradeSetup other, {Duration window = const Duration(minutes: 30)}) =>
      other.setupType == setupType &&
      other.direction == direction &&
      (other.entry - entry).abs() < 0.01 &&
      other.detectedAt.difference(detectedAt).abs() <= window;

  double get riskDollars => (entry - stopLoss).abs();
  double get rewardDollars => (takeProfit - entry).abs();
  double get riskRewardRatio =>
      riskDollars == 0 ? 0 : double.parse((rewardDollars / riskDollars).toStringAsFixed(2));

  /// The fraction of the lot Automatic Partial Take-Profit used to close
  /// while that feature existed (2026-09-20 to 2026-09-21, see
  /// [partialTpExecuted]'s own doc comment) — frozen here rather than read
  /// from AppConfig (whose PARTIAL_TP_PERCENT setting was removed along
  /// with the feature) purely so [_realizedDelta] can still correctly
  /// reconstruct a trade that genuinely partial-closed back when it was
  /// live. Every such trade used the default 50%; this was never actually
  /// reconfigured in practice.
  static const double _legacyPartialTakeProfitFraction = 0.5;

  /// The exit price move actually realized, signed positive on the
  /// winning side of Entry — the shared basis for [realizedRiskReward],
  /// [pips] and [pnlDollars]. Null while still open.
  ///
  /// Blended for a HISTORICAL Partial Take-Profit + Break-Even trade only
  /// (see [partialTpExecuted]): [_legacyPartialTakeProfitFraction] of the
  /// position already banked its profit at [partialClosePrice] (the
  /// broker's actual fill — or, for a setup persisted before that field
  /// existed, an approximation at [breakEvenTriggerPrice], the level the
  /// broker sync intended to close it at) BEFORE the remainder resolved at
  /// [closedPrice]. Without this blend, such a trade showed as a flat
  /// "0 pips" loss, silently discarding the profit already locked in. A
  /// trade opened after the feature's removal never sets [partialTpExecuted],
  /// so this always falls straight through to the simple, un-blended delta
  /// for anything new — a clean binary Break-Even-or-target result.
  double? get _realizedDelta {
    if (closedPrice == null) return null;
    final finalDelta =
        direction == TradeDirection.buy ? closedPrice! - effectiveEntry : effectiveEntry - closedPrice!;
    if (!partialTpExecuted) return finalDelta;
    final fillPrice = partialClosePrice ?? breakEvenTriggerPrice;
    final partialDelta = direction == TradeDirection.buy ? fillPrice - effectiveEntry : effectiveEntry - fillPrice;
    const fraction = _legacyPartialTakeProfitFraction;
    return fraction * partialDelta + (1 - fraction) * finalDelta;
  }

  /// The ACTUAL realized Risk:Reward once closed, relative to the original
  /// risk (entry-to-SL distance). Null while still open.
  double? get realizedRiskReward {
    final delta = _realizedDelta;
    if (delta == null || riskDollars == 0) return null;
    return double.parse((delta / riskDollars).toStringAsFixed(2));
  }

  /// XAUUSD pip convention used throughout this codebase: $0.10 = 1 pip
  /// (see AppConfig.interestZoneBufferDollars' own comment for the same
  /// convention). Public (2026-09-14) so SignalChecker's Minimum
  /// Take-Profit Distance filter converts $ -> pips the exact same way
  /// this class does internally, rather than duplicating the constant.
  static const double dollarsPerPip = 0.10;

  /// Signed pips won (positive) or lost (negative) once closed — null
  /// while still open. Trade Performance Analytics (trade_history_screen.
  /// dart) sums this across closed trades for "Net Pips".
  double? get pips {
    final delta = _realizedDelta;
    return delta == null ? null : double.parse((delta / dollarsPerPip).toStringAsFixed(1));
  }

  /// Signed price-point P/L (the same delta [pips] is derived from, just
  /// in raw $ terms rather than pips) — this app has no lot-size/position-
  /// sizing concept, so this is NOT real account-currency P/L, just the
  /// entry-to-exit price move each trade actually resolved to.
  double? get pnlDollars {
    final delta = _realizedDelta;
    return delta == null ? null : double.parse(delta.toStringAsFixed(2));
  }

  String get directionLabel => direction == TradeDirection.buy ? 'BUY' : 'SELL';
  String get emoji => direction == TradeDirection.buy ? '🟢' : '🔴';

  /// e.g. "1H S/R Retest BUY" — timeframe + structure + direction in one line.
  String get setupLabel => '$timeframeLabel ${setupType.label} $directionLabel';

  /// UI confidence badge derived from [confluenceScore] (see SignalCard).
  /// Rule 4 (AppConfig.minConfluenceScore, currently 50) already guarantees
  /// every setup that reaches the user scores >= 50, so this always
  /// resolves to one of the three tiers below for a freshly fired setup —
  /// the null case only applies to a setup persisted before scoring
  /// existed (confluenceScore left at its 0 default).
  String? get confidenceBadge {
    if (confluenceScore >= 75) return '🔥 High Confluence';
    if (confluenceScore >= 60) return '⚡ Standard Setup';
    if (confluenceScore >= 50) return '🎯 Moderate Setup';
    return null;
  }

  /// Short label for the resolved-outcome ribbon (SignalCard) — null while
  /// still [TradeOutcome.open].
  String? get outcomeLabel => switch (outcome) {
        TradeOutcome.open => null,
        TradeOutcome.win => '🎯 TP Hit',
        TradeOutcome.loss => breakEvenActive ? '⚖️ Break-Even (SL @ Entry)' : '🛑 SL Hit',
        TradeOutcome.manualClose => '✋ Manually Closed',
      };

  /// Post-trade "why it won/lost" explanation for the Trade Analytics
  /// feed's expandable analysis section — derived entirely from fields
  /// already on this setup (outcome, breakEvenActive, slWasClamped,
  /// realizedRiskReward), so it's instant and needs no network round trip.
  /// Null while still [TradeOutcome.open] (nothing to explain yet).
  String? get postMortemReason {
    switch (outcome) {
      case TradeOutcome.open:
        return null;
      case TradeOutcome.win:
        if (breakEvenActive) {
          return 'Take-Profit hit at 1:${riskRewardRatio.toStringAsFixed(1)} — the trade had already reached '
              'break-even (1:1) before running on to the full target.';
        }
        return 'Take-Profit hit at 1:${riskRewardRatio.toStringAsFixed(1)} — price followed through on the '
            'original thesis without a meaningful pullback.';
      case TradeOutcome.loss:
        if (breakEvenActive) {
          return 'Closed at Break-Even (${pips == null ? "+0.0" : "${pips! >= 0 ? "+" : ""}${pips!.toStringAsFixed(1)}"} '
              'pips) — price reached the 1:1 R:R trigger, then reversed back through Entry.';
        }
        if (slWasClamped) {
          return 'Stop-Loss hit before Take-Profit. The SL had to be widened to the \$5.00 minimum guard, so the '
              'structural invalidation level was looser than the raw zone/wick distance.';
        }
        return 'SL Hit — price swept through the structural stop before Take-Profit was reached, consistent with '
            'a high-volatility move (news spike or a trend running against DXY) rather than a clean invalidation.';
      case TradeOutcome.manualClose:
        final pipsText = pips == null ? '0.0' : '${pips! >= 0 ? "+" : ""}${pips!.toStringAsFixed(1)}';
        return 'Manually closed by the trader at $pipsText pips, before SL or TP was reached.';
    }
  }

  /// Actionable, execution-focused tip paired with [postMortemReason].
  /// Deliberately deterministic/rule-based rather than LLM-generated —
  /// this reads instantly for every card in a long history list.
  String? get postMortemAdvice {
    switch (outcome) {
      case TradeOutcome.open:
        return null;
      case TradeOutcome.win:
        if (breakEvenActive) {
          return 'Consider a partial close at 1:1 instead of moving the full stop to Entry — it locks in some '
              'gain immediately while still letting a runner target the full 1:${riskRewardRatio.toStringAsFixed(1)}.';
        }
        return 'Execution matched the plan. No change needed for this setup type.';
      case TradeOutcome.loss:
        if (breakEvenActive) {
          return 'Consider taking partial profit at the 1:1 Break-Even trigger instead of only moving the SL there — '
              'that locks in real pips instead of a scratch trade on a reversal back through Entry.';
        }
        if (slWasClamped) {
          return 'This setup needed the \$5.00 SL guard rather than a clean structural stop — treat clamped-SL '
              'setups as lower-confidence and consider sizing down or requiring extra confluence before entry.';
        }
        return 'Consider applying an ATR-based Stop-Loss during high-volatility conditions instead of a fixed '
            'structural distance, and checking DXY correlation before entry — a XAUUSD $directionLabel against '
            "DXY's own trend removes one of the strongest cross-asset confirmations from the setup.";
      case TradeOutcome.manualClose:
        if ((pips ?? 0) >= 0) {
          return 'Banking profit manually is reasonable, but compare against the original Take-Profit to see if '
              'pips were left on the table by exiting early.';
        }
        return 'Manual exits at a loss should be rare — confirm the original Stop-Loss level hadn\'t already been '
            'reached before intervening, rather than closing early on discretion.';
    }
  }

  Map<String, dynamic> toJson() => {
        'symbol': symbol,
        'direction': directionLabel,
        'timeframe': timeframeLabel,
        'setup_type': setupType.name,
        'entry': entry,
        'stop_loss': stopLoss,
        'take_profit': takeProfit,
        'pattern': pattern.name,
        'detected_at': detectedAt.toIso8601String(),
        'ai_reason': aiReason,
        'risk_reward': riskRewardRatio,
        'sl_was_clamped': slWasClamped,
        'confluence_score': confluenceScore,
        'outcome': outcome.name,
        'closed_price': closedPrice,
        'closed_at': closedAt?.toIso8601String(),
        'break_even_active': breakEvenActive,
        'data_source': dataSource,
        'lot_size': lotSize,
        'broker_ticket': brokerTicket,
        'actual_fill_price': actualFillPrice,
        'partial_tp_executed': partialTpExecuted,
        'partial_close_price': partialClosePrice,
        'break_even_synced': breakEvenSynced,
      };

  /// Mirrors [toJson] — used to rehydrate a TradeSetup sent across an
  /// isolate boundary (foreground-service task -> UI) or read back from
  /// local persistence. `setup_type` defaults to confluence,
  /// `sl_was_clamped`/`confluence_score` default to false/0, and `outcome`
  /// defaults to open, for entries persisted before those fields existed.
  factory TradeSetup.fromJson(Map<String, dynamic> json) {
    return TradeSetup(
      symbol: json['symbol'] as String,
      direction: (json['direction'] as String) == 'BUY' ? TradeDirection.buy : TradeDirection.sell,
      timeframeLabel: json['timeframe'] as String,
      setupType: SetupType.values.byName(json['setup_type'] as String? ?? SetupType.confluence.name),
      entry: (json['entry'] as num).toDouble(),
      stopLoss: (json['stop_loss'] as num).toDouble(),
      takeProfit: (json['take_profit'] as num).toDouble(),
      pattern: CandlePattern.values.byName(json['pattern'] as String),
      detectedAt: DateTime.parse(json['detected_at'] as String),
      slWasClamped: json['sl_was_clamped'] as bool? ?? false,
      confluenceScore: (json['confluence_score'] as num?)?.toInt() ?? 0,
      aiReason: json['ai_reason'] as String? ?? '',
      outcome: TradeOutcome.values.byName(json['outcome'] as String? ?? TradeOutcome.open.name),
      closedPrice: (json['closed_price'] as num?)?.toDouble(),
      closedAt: json['closed_at'] == null ? null : DateTime.parse(json['closed_at'] as String),
      breakEvenActive: json['break_even_active'] as bool? ?? false,
      dataSource: json['data_source'] as String?,
      lotSize: (json['lot_size'] as num?)?.toDouble(),
      brokerTicket: (json['broker_ticket'] as num?)?.toInt(),
      actualFillPrice: (json['actual_fill_price'] as num?)?.toDouble(),
      partialTpExecuted: json['partial_tp_executed'] as bool? ?? false,
      partialClosePrice: (json['partial_close_price'] as num?)?.toDouble(),
      breakEvenSynced: json['break_even_synced'] as bool? ?? false,
    );
  }
}
