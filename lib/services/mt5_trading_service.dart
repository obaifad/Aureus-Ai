import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config/app_config.dart';
import '../models/pivot.dart';
import '../models/trade_setup.dart';
import 'app_logger.dart';
import 'data_service.dart' show bridgeHeaders;

/// Live account snapshot from the MT5 bridge's `/account` endpoint —
/// [balance]/[equity] feed Dynamic Position Sizing (see RiskEngine.
/// calculateLotSize). Equity (not Balance) is what an open trade's real
/// risk is drawn against, so callers should prefer it for sizing.
class AccountSnapshot {
  final bool loggedIn;
  final double balance;
  final double equity;
  final String currency;
  final bool tradeAllowed;
  const AccountSnapshot({
    required this.loggedIn,
    required this.balance,
    required this.equity,
    required this.currency,
    required this.tradeAllowed,
  });
}

/// A currently OPEN broker position, from `/positions`.
class OpenPosition {
  final int ticket;
  final String symbol;
  final TradeDirection direction;
  final double volume;
  final double priceOpen;
  final double stopLoss;
  final double takeProfit;
  final double profit;
  const OpenPosition({
    required this.ticket,
    required this.symbol,
    required this.direction,
    required this.volume,
    required this.priceOpen,
    required this.stopLoss,
    required this.takeProfit,
    required this.profit,
  });
}

/// Result of a market order / partial-close / SL-modify request.
class OrderResult {
  final bool success;
  final int? ticket;
  final double? price;
  final String? error;

  /// The lot the bridge actually sent (it re-sizes in the account's own currency).
  final double? volume;
  const OrderResult({required this.success, this.ticket, this.price, this.error, this.volume});
}

/// What the bridge answered when a trade was proposed for approval.
class PendingSubmission {
  /// pending | blocked | failed | error | unreachable
  final String state;
  final DateTime? expiresAt;
  final String? reason;
  const PendingSubmission({required this.state, this.expiresAt, this.reason});
  bool get isPending => state == 'pending';
}

/// A proposal's current state on the bridge (from `/signals/{uid}`).
class SignalStatus {
  /// pending | executing | executed | rejected | expired | blocked | failed
  final String state;
  final bool notFound;
  final int? ticket;
  final double? price;
  final double? volume;
  final String? reason;
  const SignalStatus({required this.state, this.notFound = false, this.ticket, this.price, this.volume, this.reason});
}

/// The bridge's account-level daily loss guard (from `/risk/status`).
class RiskStatus {
  /// False when the account's equity could not be read at all.
  final bool available;
  final bool locked;
  final double limitPercent;
  final double? lossPercent;
  final double? lockedLossPercent;
  final double? equity;
  final double? baseline;
  final String? baselineSource;
  final int overridesToday;
  final String onBreach;
  const RiskStatus({
    required this.available,
    required this.locked,
    required this.limitPercent,
    this.lossPercent,
    this.lockedLossPercent,
    this.equity,
    this.baseline,
    this.baselineSource,
    this.overridesToday = 0,
    this.onBreach = 'block',
  });

  /// One override is allowed per UTC day.
  bool get canOverride => locked && overridesToday < 1;

  factory RiskStatus.fromJson(Map<String, dynamic> j) => RiskStatus(
        available: j['available'] == true,
        locked: j['locked'] == true,
        limitPercent: (j['limit_percent'] as num?)?.toDouble() ?? 0,
        lossPercent: (j['loss_percent'] as num?)?.toDouble(),
        lockedLossPercent: (j['locked_loss_percent'] as num?)?.toDouble(),
        equity: (j['equity'] as num?)?.toDouble(),
        baseline: (j['baseline'] as num?)?.toDouble(),
        baselineSource: j['baseline_source'] as String?,
        overridesToday: (j['overrides_today'] as num?)?.toInt() ?? 0,
        onBreach: j['on_breach'] as String? ?? 'block',
      );
}

class RiskOverrideResult {
  final bool ok;
  final String message;
  const RiskOverrideResult({required this.ok, required this.message});
}

/// A position as the broker reports it (from `/reconcile`).
class BrokerPosition {
  final int ticket;
  final String symbol;
  final TradeDirection direction;
  final double volume;
  final double priceOpen;
  final double stopLoss;
  final double takeProfit;
  final double profit;
  final int magic;
  final DateTime? timeOpen;
  const BrokerPosition({
    required this.ticket,
    required this.symbol,
    required this.direction,
    required this.volume,
    required this.priceOpen,
    required this.stopLoss,
    required this.takeProfit,
    required this.profit,
    required this.magic,
    this.timeOpen,
  });
}

/// A position that is fully closed at the broker, folded from its deal
/// history: real open/close prices, net profit and the reason it closed.
class BrokerClosedPosition {
  final int ticket;
  final TradeDirection direction;
  final double priceOpen;
  final double priceClose;
  final int timeClose; // UTC seconds
  final double profit;
  final String reason;
  const BrokerClosedPosition({
    required this.ticket,
    required this.direction,
    required this.priceOpen,
    required this.priceClose,
    required this.timeClose,
    required this.profit,
    required this.reason,
  });
}

class ReconcileSnapshot {
  final List<BrokerPosition> positions;
  final List<BrokerClosedPosition> closed;

  /// False when the broker's deal history could not be read — in that case
  /// an empty [closed] means "unknown", never "nothing closed".
  final bool historyOk;
  const ReconcileSnapshot({required this.positions, required this.closed, required this.historyOk});
}

/// Result of closing ONE position via the bridge's `/order/close`.
class CloseOutcome {
  final bool success;
  final double? price;
  final String? error;

  /// The bridge could not find the position — it is already closed.
  final bool notFound;
  const CloseOutcome({required this.success, this.price, this.error, this.notFound = false});
}

/// One position's result inside `/order/close_all`.
class CloseResult {
  final int ticket;
  final bool success;
  final double? price;
  final String? error;
  const CloseResult({required this.ticket, required this.success, this.price, this.error});
}

class CloseAllOutcome {
  final bool success;
  final List<CloseResult> results;
  final String? error;
  const CloseAllOutcome({required this.success, this.results = const [], this.error});
}

/// -------------------------------------------------------------------
/// TRADE EXECUTION CLIENT — the MT5 bridge (bridge/mt5_bridge_server.py)
/// -------------------------------------------------------------------
/// Everything here runs off the SAME local bridge every other live feature
/// in this app already depends on — no paid third-party service is ever
/// involved. Every method fails SAFE: a bridge that's unreachable, in mock
/// mode, or explicitly disabled ([AppConfig.disableMt5Bridge]) returns null/
/// empty/false rather than throwing, so a transient bridge outage degrades
/// a live-trading feature to "skip this cycle", never to a crash — callers
/// (SignalChecker) are responsible for treating that as "can't verify,
/// don't risk it" for anything that would open/modify real money.
class Mt5TradingService {
  /// [client] is injectable for tests; production uses the global http client.
  Mt5TradingService({http.Client? client}) : _client = client;

  final http.Client? _client;

  bool get _available => !AppConfig.useMockData && !AppConfig.disableMt5Bridge;

  Future<http.Response> _postJson(String path, Object body, {Duration timeout = const Duration(seconds: 20)}) {
    final uri = Uri.parse('${AppConfig.bridgeBaseUrl}$path');
    final headers = {...bridgeHeaders(), 'Content-Type': 'application/json'};
    final client = _client;
    final request = client != null
        ? client.post(uri, headers: headers, body: jsonEncode(body))
        : http.post(uri, headers: headers, body: jsonEncode(body));
    return request.timeout(timeout);
  }

  Future<AccountSnapshot?> getAccount() async {
    if (!_available) return null;
    try {
      final uri = Uri.parse('${AppConfig.bridgeBaseUrl}/account');
      final response = await http.get(uri, headers: bridgeHeaders()).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        AppLogger.log('Mt5TradingService: /account returned ${response.statusCode}');
        return null;
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (data['logged_in'] != true) {
        AppLogger.log('Mt5TradingService: MT5 not logged in (${data['error']})');
        return null;
      }
      return AccountSnapshot(
        loggedIn: true,
        balance: (data['balance'] as num).toDouble(),
        equity: (data['equity'] as num).toDouble(),
        currency: data['currency'] as String? ?? '',
        tradeAllowed: data['trade_allowed'] as bool? ?? false,
      );
    } catch (e) {
      AppLogger.log('Mt5TradingService: /account failed: $e');
      return null;
    }
  }

  /// Single Active Position Guard: open positions for [symbol] (defaults to
  /// [AppConfig.brokerSymbol]). Returns an EMPTY list (not null) on any
  /// failure to read — a bridge hiccup should never be silently read as
  /// "no position open" by a caller deciding whether to fire a new one, so
  /// [getOpenPositions] callers must check [lastFetchFailed] rather than
  /// trust an empty list alone when that distinction matters.
  bool lastFetchFailed = false;

  Future<List<OpenPosition>> getOpenPositions({String? symbol}) async {
    lastFetchFailed = false;
    if (!_available) {
      lastFetchFailed = true;
      return const [];
    }
    try {
      final uri = Uri.parse('${AppConfig.bridgeBaseUrl}/positions')
          .replace(queryParameters: {'symbol': symbol ?? AppConfig.brokerSymbol});
      final response = await http.get(uri, headers: bridgeHeaders()).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        AppLogger.log('Mt5TradingService: /positions returned ${response.statusCode}');
        lastFetchFailed = true;
        return const [];
      }
      final List<dynamic> raw = jsonDecode(response.body) as List<dynamic>;
      return raw.map((e) {
        final m = e as Map<String, dynamic>;
        return OpenPosition(
          ticket: (m['ticket'] as num).toInt(),
          symbol: m['symbol'] as String,
          direction: (m['type'] as String).toLowerCase() == 'buy' ? TradeDirection.buy : TradeDirection.sell,
          volume: (m['volume'] as num).toDouble(),
          priceOpen: (m['price_open'] as num).toDouble(),
          stopLoss: (m['sl'] as num).toDouble(),
          takeProfit: (m['tp'] as num).toDouble(),
          profit: (m['profit'] as num).toDouble(),
        );
      }).toList();
    } catch (e) {
      AppLogger.log('Mt5TradingService: /positions failed: $e');
      lastFetchFailed = true;
      return const [];
    }
  }

  /// Live Spread Protection: current bid/ask spread in PIPS (this
  /// codebase's convention — $0.10 on XAUUSD, see TradeSetup.dollarsPerPip),
  /// straight off the live tick. Null when it couldn't be read.
  Future<double?> getSpreadPips({String? symbol}) async {
    if (!_available) return null;
    try {
      final uri = Uri.parse('${AppConfig.bridgeBaseUrl}/tick')
          .replace(queryParameters: {'symbol': symbol ?? AppConfig.brokerSymbol});
      final response = await http.get(uri, headers: bridgeHeaders()).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        AppLogger.log('Mt5TradingService: /tick returned ${response.statusCode}');
        return null;
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final bid = (data['bid'] as num).toDouble();
      final ask = (data['ask'] as num).toDouble();
      final spreadDollars = ask - bid;
      return spreadDollars / TradeSetup.dollarsPerPip;
    } catch (e) {
      AppLogger.log('Mt5TradingService: /tick (spread) failed: $e');
      return null;
    }
  }

  /// Opens a REAL market order on the broker (only ever called by
  /// SignalChecker when [AppConfig.enableAutoTrading] is true and every
  /// safety gate above already passed).
  Future<OrderResult> openMarketOrder({
    required TradeDirection direction,
    required double volume,
    required double stopLoss,
    required double takeProfit,
    String? symbol,

    /// The signal's own entry price: the bridge refuses the order if the market has run too far from it.
    double? entry,

    /// True: the bridge sizes the lot itself (live equity, real stop distance, account currency); [volume]
    /// is then only an estimate.
    bool bridgeSizing = false,
  }) async {
    if (!_available) return const OrderResult(success: false, error: 'MT5 bridge unavailable');
    try {
      final uri = Uri.parse('${AppConfig.bridgeBaseUrl}/order/open');
      final response = await http
          .post(
            uri,
            headers: {...bridgeHeaders(), 'Content-Type': 'application/json'},
            body: jsonEncode({
              'symbol': symbol ?? AppConfig.brokerSymbol,
              'direction': direction == TradeDirection.buy ? 'buy' : 'sell',
              'volume': volume,
              'stop_loss': stopLoss,
              'take_profit': takeProfit,
              if (entry != null) 'entry': entry,
              if (bridgeSizing) 'bridge_sizing': true,
            }),
          )
          .timeout(const Duration(seconds: 15));
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode != 200 || data['success'] != true) {
        final error = data['error']?.toString() ?? 'HTTP ${response.statusCode}';
        AppLogger.log('Mt5TradingService: order open rejected: $error');
        return OrderResult(success: false, error: error);
      }
      return OrderResult(
        success: true,
        ticket: (data['ticket'] as num).toInt(),
        price: (data['price'] as num).toDouble(),
        volume: (data['volume'] as num?)?.toDouble(),
      );
    } catch (e) {
      AppLogger.log('Mt5TradingService: order open failed: $e');
      return OrderResult(success: false, error: e.toString());
    }
  }

  /// Closes [volume] lots of [ticket]. UNUSED as of 2026-09-21 — Automatic
  /// Partial Take-Profit was removed (explicit request: "بدون قفل جزئي،
  /// بس تحريك الستوب للدخول عند 1R") in favor of a plain Break-Even Stop
  /// Loss move on the FULL lot (see SignalChecker._resolveOpenTrades).
  /// Kept, tested, and still fully functional (mirrors
  /// BreakoutMomentumEngine's own precedent of leaving retired-but-working
  /// methods in place — see SignalChecker._evaluateBreakoutTrigger's doc
  /// comment) in case a future request wants partial-closing back. Returns
  /// the ACTUAL fill price on success, or null on failure.
  Future<double?> closePartial({required int ticket, required double volume}) async {
    if (!_available) return null;
    try {
      final uri = Uri.parse('${AppConfig.bridgeBaseUrl}/order/close_partial');
      final response = await http
          .post(
            uri,
            headers: {...bridgeHeaders(), 'Content-Type': 'application/json'},
            body: jsonEncode({'ticket': ticket, 'volume': volume}),
          )
          .timeout(const Duration(seconds: 15));
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode != 200 || data['success'] != true) {
        AppLogger.log('Mt5TradingService: partial close rejected for #$ticket: ${data['error']}');
        return null;
      }
      return (data['price'] as num?)?.toDouble();
    } catch (e) {
      AppLogger.log('Mt5TradingService: partial close failed for #$ticket: $e');
      return null;
    }
  }

  /// Proposes [setup] for the owner's Telegram approval. Nothing is traded by
  /// this call: the bridge asks, waits, re-checks the market and only then trades.
  Future<PendingSubmission> submitPending(TradeSetup setup) async {
    if (!_available) return const PendingSubmission(state: 'unreachable', reason: 'MT5 bridge unavailable');
    try {
      final response = await _postJson('/signals/pending', {
        'uid': setup.uid,
        'symbol': AppConfig.brokerSymbol,
        'direction': setup.directionLabel,
        'entry': setup.entry,
        'stop_loss': setup.stopLoss,
        'take_profit': setup.takeProfit,
        'volume': setup.lotSize ?? AppConfig.minLotSize,
        'label': '${setup.timeframeLabel} ${setup.setupType.label}',
        'score': setup.confluenceScore,
        'reason': '${setup.pattern.shapeLabel} confirmation at a ${setup.setupType.label} level',
      });
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode == 200) {
        final expires = data['expires_at'];
        return PendingSubmission(
          state: data['state'] as String? ?? 'failed',
          expiresAt: expires is num ? DateTime.fromMillisecondsSinceEpoch((expires * 1000).round(), isUtc: true) : null,
          reason: (data['reason'] ?? (data['result'] as Map?)?['error'])?.toString(),
        );
      }
      final detail = data['detail'];
      return PendingSubmission(
        state: 'error',
        reason: detail is Map ? '${detail['code']}: ${detail['message']}' : 'HTTP ${response.statusCode}',
      );
    } catch (e) {
      AppLogger.log('Mt5TradingService: proposal failed: $e');
      return PendingSubmission(state: 'unreachable', reason: e.toString());
    }
  }

  /// The state of a proposal. Null when the bridge cannot be read at all;
  /// [SignalStatus.notFound] when it answered that it knows no such proposal.
  Future<SignalStatus?> getSignal(String uid) async {
    if (!_available) return null;
    try {
      final uri = Uri.parse('${AppConfig.bridgeBaseUrl}/signals/${Uri.encodeComponent(uid)}');
      final client = _client;
      final response = await (client != null
              ? client.get(uri, headers: bridgeHeaders())
              : http.get(uri, headers: bridgeHeaders()))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode == 404) return const SignalStatus(state: 'unknown', notFound: true);
      if (response.statusCode != 200) return null;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final result = (data['result'] as Map?)?.cast<String, dynamic>();
      return SignalStatus(
        state: data['state'] as String? ?? 'unknown',
        ticket: (result?['ticket'] as num?)?.toInt(),
        price: (result?['price'] as num?)?.toDouble(),
        volume: (result?['volume'] as num?)?.toDouble(),
        reason: (result?['reason'] ?? result?['error'])?.toString(),
      );
    } catch (e) {
      AppLogger.log('Mt5TradingService: signal status failed: $e');
      return null;
    }
  }

  /// The daily loss guard's current state. Null when the bridge can't be
  /// read (or in mock/standalone mode) — callers must not treat that as
  /// "not locked" for anything that opens risk; the bridge itself refuses
  /// orders in that case.
  Future<RiskStatus?> getRiskStatus() async {
    if (!_available) return null;
    try {
      final uri = Uri.parse('${AppConfig.bridgeBaseUrl}/risk/status');
      final client = _client;
      final response = await (client != null
              ? client.get(uri, headers: bridgeHeaders())
              : http.get(uri, headers: bridgeHeaders()))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      return RiskStatus.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
    } catch (e) {
      AppLogger.log('Mt5TradingService: risk status failed: $e');
      return null;
    }
  }

  /// Releases a daily-loss lock by rebasing the loss budget to the current
  /// equity. The bridge allows it once per UTC day and audits it.
  Future<RiskOverrideResult> overrideDailyLoss() async {
    if (!_available) return const RiskOverrideResult(ok: false, message: 'The MT5 bridge is not connected.');
    try {
      final response = await _postJson('/risk/override', {'confirm': true, 'updated_by': 'app'});
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode == 200) {
        return const RiskOverrideResult(ok: true, message: 'Unlocked — a fresh loss budget starts from the current equity.');
      }
      final detail = data['detail'];
      return RiskOverrideResult(
        ok: false,
        message: detail is Map ? '${detail['message']}' : 'Rejected by the bridge (${response.statusCode}).',
      );
    } catch (e) {
      return RiskOverrideResult(ok: false, message: 'Could not reach the bridge: $e');
    }
  }

  /// Why the last /reconcile failed — logged once per new reason, not on every scan (2026-10-09: the bridge now
  /// answers 503 until a fresh tick confirms the MT5 server-time offset, which in the gold daily break or a weekend
  /// lasts until the market reopens).
  static String? _lastReconcileFailure;

  /// The broker's own view: open positions plus recently closed ones with
  /// their real prices and results. Null when it cannot be read — callers
  /// must then conclude nothing.
  Future<ReconcileSnapshot?> fetchReconcile({String? symbol, int sinceHours = 96}) async {
    if (!_available) return null;
    try {
      final uri = Uri.parse('${AppConfig.bridgeBaseUrl}/reconcile').replace(queryParameters: {
        if (symbol != null) 'symbol': symbol,
        'since_hours': '$sinceHours',
      });
      final client = _client;
      final response = await (client != null
              ? client.get(uri, headers: bridgeHeaders())
              : http.get(uri, headers: bridgeHeaders()))
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) {
        final reason = response.statusCode == 503 && response.body.contains('offset not confirmed')
            ? 'the bridge has not confirmed the MT5 server time yet (no fresh tick) — trade history left untouched'
            : 'returned ${response.statusCode}';
        if (reason != _lastReconcileFailure) AppLogger.log('Mt5TradingService: /reconcile $reason');
        _lastReconcileFailure = reason;
        return null;
      }
      if (_lastReconcileFailure != null) {
        AppLogger.log('Mt5TradingService: /reconcile available again');
        _lastReconcileFailure = null;
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      TradeDirection dir(Object? t) => t == 'buy' ? TradeDirection.buy : TradeDirection.sell;
      return ReconcileSnapshot(
        historyOk: data['history_ok'] == true,
        positions: [
          for (final raw in (data['positions'] as List? ?? const []))
            BrokerPosition(
              ticket: ((raw as Map)['ticket'] as num).toInt(),
              symbol: raw['symbol'] as String,
              direction: dir(raw['type']),
              volume: (raw['volume'] as num).toDouble(),
              priceOpen: (raw['price_open'] as num).toDouble(),
              stopLoss: (raw['sl'] as num).toDouble(),
              takeProfit: (raw['tp'] as num).toDouble(),
              profit: (raw['profit'] as num).toDouble(),
              magic: (raw['magic'] as num).toInt(),
              timeOpen: raw['time_open'] == null
                  ? null
                  : DateTime.fromMillisecondsSinceEpoch((raw['time_open'] as num).toInt() * 1000, isUtc: true),
            ),
        ],
        closed: [
          for (final raw in (data['closed'] as List? ?? const []))
            BrokerClosedPosition(
              ticket: ((raw as Map)['ticket'] as num).toInt(),
              direction: dir(raw['type']),
              priceOpen: (raw['price_open'] as num).toDouble(),
              priceClose: (raw['price_close'] as num).toDouble(),
              timeClose: (raw['time_close'] as num).toInt(),
              profit: (raw['profit'] as num).toDouble(),
              reason: raw['reason'] as String? ?? 'other',
            ),
        ],
      );
    } catch (e) {
      AppLogger.log('Mt5TradingService: reconcile fetch failed: $e');
      return null;
    }
  }

  /// Closes the WHOLE position [ticket] at market. A timeout or a dropped
  /// connection comes back as a failure even though the order may have gone
  /// through — callers keep the trade open and a retry then answers
  /// [CloseOutcome.notFound], which is the signal that it really is closed.
  Future<CloseOutcome> closePosition(int ticket) async {
    if (!_available) return const CloseOutcome(success: false, error: 'MT5 bridge unavailable');
    try {
      final response = await _postJson('/order/close', {'ticket': ticket});
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode == 200 && data['success'] == true) {
        return CloseOutcome(success: true, price: (data['price'] as num?)?.toDouble());
      }
      final error = data['error']?.toString() ?? 'HTTP ${response.statusCode}';
      AppLogger.log('Mt5TradingService: close rejected for #$ticket: $error');
      return CloseOutcome(success: false, error: error, notFound: data['not_found'] == true);
    } catch (e) {
      AppLogger.log('Mt5TradingService: close failed for #$ticket: $e');
      return CloseOutcome(success: false, error: e.toString());
    }
  }

  /// Emergency exit: closes every open position on [symbol] (default: the
  /// app's gold symbol, so unrelated manual trades are left alone).
  Future<CloseAllOutcome> closeAllPositions({String? symbol}) async {
    if (!_available) return const CloseAllOutcome(success: false, error: 'MT5 bridge unavailable');
    try {
      final response = await _postJson('/order/close_all', {'symbol': symbol ?? AppConfig.brokerSymbol});
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode != 200) {
        return CloseAllOutcome(success: false, error: data['detail']?.toString() ?? 'HTTP ${response.statusCode}');
      }
      final results = [
        for (final raw in (data['closed'] as List? ?? const []))
          CloseResult(
            ticket: ((raw as Map)['ticket'] as num).toInt(),
            success: raw['success'] == true,
            price: (raw['price'] as num?)?.toDouble(),
            error: raw['error']?.toString(),
          ),
      ];
      return CloseAllOutcome(success: data['success'] == true, results: results, error: data['error']?.toString());
    } catch (e) {
      AppLogger.log('Mt5TradingService: close-all failed: $e');
      return CloseAllOutcome(success: false, error: e.toString());
    }
  }

  /// Automatic Break-Even: moves [ticket]'s Stop Loss to [sl] (Entry, once
  /// 1:1 R:R is reached).
  Future<bool> modifyStopLoss({required int ticket, required double sl, double? takeProfit}) async {
    if (!_available) return false;
    try {
      final uri = Uri.parse('${AppConfig.bridgeBaseUrl}/order/modify_sl');
      final response = await http
          .post(
            uri,
            headers: {...bridgeHeaders(), 'Content-Type': 'application/json'},
            body: jsonEncode({
              'ticket': ticket,
              'stop_loss': sl,
              if (takeProfit != null) 'take_profit': takeProfit,
            }),
          )
          .timeout(const Duration(seconds: 15));
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode != 200 || data['success'] != true) {
        AppLogger.log('Mt5TradingService: SL modify rejected for #$ticket: ${data['error']}');
        return false;
      }
      return true;
    } catch (e) {
      AppLogger.log('Mt5TradingService: SL modify failed for #$ticket: $e');
      return false;
    }
  }
}
