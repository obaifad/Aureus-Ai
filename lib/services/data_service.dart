import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import '../config/app_config.dart';
import '../models/candle.dart';
import 'app_logger.dart';
import 'connection_status_service.dart';
import 'twelve_data_data_service.dart';
import 'yahoo_finance_data_service.dart';

/// Abstract data source: anything that can hand Aureus AI a list of
/// OHLC candles for XAUUSD on a given timeframe (in minutes).
///
/// Contract for every implementation: candles are chronological, [Candle.
/// time] is the candle OPEN time in real UTC, and the LAST element may be
/// the still-forming candle.
abstract class DataService {
  Future<List<Candle>> getCandles({required int timeframeMinutes, int count = 300});

  /// Factory: picks the mock generator or the real (failover-aware) client
  /// based on AppConfig.useMockData.
  factory DataService() => AppConfig.useMockData ? MockDataService() : FailoverDataService();
}

/// Headers every authenticated bridge request needs (the bridge rejects
/// /candles and /ai-commentary with 401 when BRIDGE_API_KEY is set there
/// and this header is missing).
Map<String, String> bridgeHeaders() => {
      if (AppConfig.bridgeApiKey.isNotEmpty) 'X-API-Key': AppConfig.bridgeApiKey,
    };

/// -------------------------------------------------------------------
/// REAL DATA SOURCE — the MT5 bridge (bridge/mt5_bridge_server.py)
/// -------------------------------------------------------------------
///   GET {bridgeBaseUrl}/candles?symbol=XAUUSD&timeframe=15&count=300
/// The bridge converts MT5's broker-server timestamps to real UTC before
/// returning them.
class Mt5BridgeDataService implements DataService {
  @override
  Future<List<Candle>> getCandles({required int timeframeMinutes, int count = 300}) async {
    final uri = Uri.parse('${AppConfig.bridgeBaseUrl}/candles').replace(queryParameters: {
      'symbol': AppConfig.brokerSymbol,
      'timeframe': timeframeMinutes.toString(),
      'count': count.toString(),
    });

    final response = await http.get(uri, headers: bridgeHeaders()).timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) {
      final body = response.body.length > 200 ? '${response.body.substring(0, 200)}…' : response.body;
      throw DataServiceException('MT5 bridge returned ${response.statusCode}: $body');
    }

    final List<dynamic> raw = jsonDecode(response.body) as List<dynamic>;
    return raw.map((e) => Candle.fromJson(e as Map<String, dynamic>)).toList();
  }
}

/// -------------------------------------------------------------------
/// FAILOVER WRAPPER
/// -------------------------------------------------------------------
/// Tries, in order: the MT5 bridge (broker feed), TwelveData (real XAU/USD
/// spot, needs TWELVE_DATA_API_KEY), then Yahoo Finance GC=F (futures —
/// real data but NOT spot; SignalChecker pauses signal generation on it
/// unless AppConfig.allowFuturesFallbackSignals). Throws if all fail rather
/// than fabricating candles. Every outcome is reported to
/// [ConnectionStatusService], and every failure reason is logged (once per
/// distinct reason, so a bridge that stays down doesn't spam the log every
/// 30 seconds).
class FailoverDataService implements DataService {
  final Mt5BridgeDataService _bridge = Mt5BridgeDataService();
  final TwelveDataDataService _twelveData = TwelveDataDataService();
  final YahooFinanceDataService _yahoo = YahooFinanceDataService();

  static final Map<String, String> _lastFailure = {};

  static void _noteFailure(String tier, Object error) {
    final message = error.toString();
    if (_lastFailure[tier] == message) return;
    _lastFailure[tier] = message;
    AppLogger.log('Data feed [$tier] failed: $message');
  }

  static void _noteSuccess(String tier) {
    if (_lastFailure.remove(tier) != null) {
      AppLogger.log('Data feed [$tier] recovered');
    }
  }

  @override
  Future<List<Candle>> getCandles({required int timeframeMinutes, int count = 300}) async {
    if (!AppConfig.disableMt5Bridge) {
      try {
        final candles = await _bridge.getCandles(timeframeMinutes: timeframeMinutes, count: count);
        _noteSuccess('MT5 Bridge');
        ConnectionStatusService.instance.report(FeedSource.liveBridge);
        return candles;
      } catch (e) {
        _noteFailure('MT5 Bridge', e);
      }
    }
    try {
      final candles = await _twelveData.getCandles(timeframeMinutes: timeframeMinutes, count: count);
      _noteSuccess('TwelveData');
      ConnectionStatusService.instance.report(FeedSource.fallbackTwelveData);
      return candles;
    } catch (e) {
      _noteFailure('TwelveData', e);
    }
    try {
      final candles = await _yahoo.getCandles(timeframeMinutes: timeframeMinutes, count: count);
      _noteSuccess('Yahoo GC=F');
      ConnectionStatusService.instance.report(FeedSource.fallbackYahoo);
      return candles;
    } catch (e) {
      _noteFailure('Yahoo GC=F', e);
    }
    ConnectionStatusService.instance.report(FeedSource.disconnected);
    throw DataServiceException('MT5 bridge, TwelveData, and Yahoo Finance fallback are all unreachable');
  }
}

/// -------------------------------------------------------------------
/// MOCK DATA SOURCE (for demoing the app without a broker connection)
/// -------------------------------------------------------------------
class MockDataService implements DataService {
  final Random _rng = Random(42);

  @override
  Future<List<Candle>> getCandles({required int timeframeMinutes, int count = 300}) async {
    await Future.delayed(const Duration(milliseconds: 150));

    final List<Candle> candles = [];
    double price = 2400.0;
    // Aligned to real candle boundaries so closed-candle logic behaves
    // exactly like it does on a live feed (last candle = forming one).
    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    final tfMs = timeframeMinutes * 60000;
    DateTime t = DateTime.fromMillisecondsSinceEpoch((nowMs ~/ tfMs) * tfMs, isUtc: true)
        .subtract(Duration(minutes: timeframeMinutes * (count - 1)));

    double trendBias = 0;
    for (int i = 0; i < count; i++) {
      if (i % 40 == 0) trendBias = (_rng.nextDouble() - 0.5) * 0.6;

      final double open = price;
      final double drift = trendBias + (_rng.nextDouble() - 0.5) * 1.2;
      final double close = open + drift;
      final double high = max(open, close) + _rng.nextDouble() * 0.8;
      final double low = min(open, close) - _rng.nextDouble() * 0.8;

      candles.add(Candle(
        time: t,
        open: open,
        high: high,
        low: low,
        close: close,
        volume: 100 + _rng.nextInt(400).toDouble(),
      ));

      price = close;
      t = t.add(Duration(minutes: timeframeMinutes));
    }
    return candles;
  }
}

class DataServiceException implements Exception {
  final String message;
  DataServiceException(this.message);
  @override
  String toString() => 'DataServiceException: $message';
}
