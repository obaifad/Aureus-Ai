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
  const OrderResult({required this.success, this.ticket, this.price, this.error});
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
  bool get _available => !AppConfig.useMockData && !AppConfig.disableMt5Bridge;

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
