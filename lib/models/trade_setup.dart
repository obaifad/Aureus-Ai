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

  /// Which feed the setup was priced from (e.g. "MT5 Bridge", "TwelveData
  /// XAU/USD") — null for setups persisted before this field existed.
  String? dataSource;

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
    this.dataSource,
  });

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
  ({TradeOutcome outcome, double exitPrice})? evaluateOutcome(Candle candle) {
    if (direction == TradeDirection.buy) {
      if (candle.low <= stopLoss) return (outcome: TradeOutcome.loss, exitPrice: stopLoss);
      if (candle.high >= takeProfit) return (outcome: TradeOutcome.win, exitPrice: takeProfit);
    } else {
      if (candle.high >= stopLoss) return (outcome: TradeOutcome.loss, exitPrice: stopLoss);
      if (candle.low <= takeProfit) return (outcome: TradeOutcome.win, exitPrice: takeProfit);
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
  }) {
    final earliest = detectedAt.toUtc().subtract(grace);
    for (final candle in candles) {
      if (candle.time.isBefore(earliest)) continue;
      final result = evaluateOutcome(candle);
      if (result != null) return result;
    }
    return null;
  }

  /// Live TICK check. A BUY position closes on the BID, a SELL position
  /// closes on the ASK — using the bid for both would stop SELLs out late
  /// and hand them TP early by the whole spread. [exitPrice] is the actual
  /// tick price (realistic fill, including slippage past the level).
  ({TradeOutcome outcome, double exitPrice})? evaluateOutcomeAtTick({required double bid, required double ask}) {
    if (direction == TradeDirection.buy) {
      if (bid <= stopLoss) return (outcome: TradeOutcome.loss, exitPrice: bid);
      if (bid >= takeProfit) return (outcome: TradeOutcome.win, exitPrice: bid);
    } else {
      if (ask >= stopLoss) return (outcome: TradeOutcome.loss, exitPrice: ask);
      if (ask <= takeProfit) return (outcome: TradeOutcome.win, exitPrice: ask);
    }
    return null;
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

  /// The ACTUAL realized Risk:Reward once closed — the exit's price delta
  /// relative to the original risk (entry-to-SL distance), signed:
  /// positive on the winning side of Entry, negative on the losing side.
  /// Derived from [closedPrice] rather than re-deriving from [outcome]
  /// directly, so it's automatically correct both for a clean SL/TP fill
  /// (exactly -1.0 on a loss, exactly [riskRewardRatio] on a win, since
  /// [evaluateOutcome] now sets closedPrice to the exact SL/TP level) AND
  /// for any trade closed before that 2026-09-14 fix, whose closedPrice
  /// may sit slightly past the SL/TP line. Null while still open.
  double? get realizedRiskReward {
    if (closedPrice == null || riskDollars == 0) return null;
    final delta = direction == TradeDirection.buy ? closedPrice! - entry : entry - closedPrice!;
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
    if (closedPrice == null) return null;
    final delta = direction == TradeDirection.buy ? closedPrice! - entry : entry - closedPrice!;
    return double.parse((delta / dollarsPerPip).toStringAsFixed(1));
  }

  /// Signed price-point P/L (the same delta [pips] is derived from, just
  /// in raw $ terms rather than pips) — this app has no lot-size/position-
  /// sizing concept, so this is NOT real account-currency P/L, just the
  /// entry-to-exit price move each trade actually resolved to.
  double? get pnlDollars {
    if (closedPrice == null) return null;
    final delta = direction == TradeDirection.buy ? closedPrice! - entry : entry - closedPrice!;
    return double.parse(delta.toStringAsFixed(2));
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
        TradeOutcome.loss => '🛑 SL Hit',
      };

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
        'data_source': dataSource,
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
      dataSource: json['data_source'] as String?,
    );
  }
}
