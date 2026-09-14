import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../models/candle.dart';
import 'data_service.dart';

/// Fallback data source used when the MT5 bridge is unreachable, tried
/// BEFORE Yahoo Finance (see FailoverDataService in data_service.dart) —
/// TwelveData's free-tier XAU/USD "Gold Spot" feed. Unlike Yahoo's GC=F
/// (COMEX futures), this tracks the actual spot price, so it's the more
/// accurate of the two real-data fallback tiers when available.
///
/// Free tier: 800 requests/day, 8 requests/minute. [_underRateLimit]
/// enforces a conservative per-minute cap client-side so a screen
/// polling every couple of seconds fails over to Yahoo instead of
/// hammering TwelveData into 429s and burning the daily quota for
/// nothing.
class TwelveDataDataService implements DataService {
  static const int _maxCallsPerMinute = 6;
  static final List<DateTime> _recentCalls = [];

  bool _underRateLimit() {
    final cutoff = DateTime.now().subtract(const Duration(minutes: 1));
    _recentCalls.removeWhere((t) => t.isBefore(cutoff));
    return _recentCalls.length < _maxCallsPerMinute;
  }

  @override
  Future<List<Candle>> getCandles({required int timeframeMinutes, int count = 300}) async {
    final apiKey = AppConfig.twelveDataApiKey;
    if (apiKey.isEmpty) {
      throw DataServiceException('No TwelveData API key configured');
    }
    if (!_underRateLimit()) {
      throw DataServiceException('TwelveData per-minute rate limit reached');
    }
    _recentCalls.add(DateTime.now());

    final uri = Uri.parse('https://api.twelvedata.com/time_series').replace(queryParameters: {
      'symbol': 'XAU/USD',
      'interval': _intervalFor(timeframeMinutes),
      'outputsize': count.toString(),
      'timezone': 'UTC',
      'apikey': apiKey,
    });

    final response = await http.get(uri).timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      throw DataServiceException('TwelveData returned ${response.statusCode}');
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    if (decoded['status'] != 'ok') {
      throw DataServiceException('TwelveData error: ${decoded['message'] ?? decoded['status']}');
    }

    final values = decoded['values'] as List?;
    if (values == null || values.isEmpty) {
      throw DataServiceException('TwelveData returned no candles');
    }

    // TwelveData returns newest-first — reverse to the chronological
    // ascending order every other DataService (and the chart) expects.
    final candles = values.reversed.map((v) {
      final map = v as Map<String, dynamic>;
      return Candle(
        time: _parseUtc(map['datetime'] as String),
        open: double.parse(map['open'] as String),
        high: double.parse(map['high'] as String),
        low: double.parse(map['low'] as String),
        close: double.parse(map['close'] as String),
        volume: double.tryParse(map['volume']?.toString() ?? '') ?? 0,
      );
    }).toList();

    return candles;
  }

  /// TwelveData's `datetime` is either "yyyy-MM-dd HH:mm:ss" (intraday)
  /// or plain "yyyy-MM-dd" (1day) — both requested/returned in UTC (see
  /// the `timezone: 'UTC'` query param above), so both are normalized to
  /// an explicit UTC ISO-8601 string before parsing rather than letting
  /// DateTime.parse guess a local offset.
  DateTime _parseUtc(String dt) {
    final iso = dt.length == 10 ? '${dt}T00:00:00Z' : '${dt.replaceFirst(' ', 'T')}Z';
    return DateTime.parse(iso);
  }

  String _intervalFor(int timeframeMinutes) => switch (timeframeMinutes) {
        1 => '1min',
        5 => '5min',
        15 => '15min',
        60 => '1h',
        240 => '4h',
        1440 => '1day',
        _ => '15min',
      };
}
