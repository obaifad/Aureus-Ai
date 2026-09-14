import 'dart:convert';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:http/http.dart' as http;

import '../models/candle.dart';
import 'data_service.dart';

/// Fallback data source used ONLY when the MT5 bridge is unreachable (see
/// FailoverDataService in data_service.dart) — Yahoo Finance's public,
/// unauthenticated chart API for COMEX Gold futures (GC=F). This tracks
/// spot XAUUSD closely but is not identical to it (futures vs. spot,
/// slightly different session hours), so it's a stopgap to keep the chart
/// moving on real market data while the bridge is down, not a calibrated
/// substitute for the broker's own feed.
class YahooFinanceDataService implements DataService {
  static const _yahooSymbol = 'GC=F';

  @override
  Future<List<Candle>> getCandles({required int timeframeMinutes, int count = 300}) async {
    final aggregateInto4h = timeframeMinutes == 240;
    final (interval, range) = _intervalAndRangeFor(timeframeMinutes);
    final uri = Uri.parse('https://query1.finance.yahoo.com/v8/finance/chart/$_yahooSymbol')
        .replace(queryParameters: {'interval': interval, 'range': range});

    final response = await http
        .get(uri, headers: {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'})
        .timeout(const Duration(seconds: 8));

    if (response.statusCode != 200) {
      throw DataServiceException('Yahoo Finance returned ${response.statusCode}');
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final result = ((decoded['chart']?['result']) as List?)?.firstOrNull as Map<String, dynamic>?;
    if (result == null) {
      throw DataServiceException('Yahoo Finance returned no chart result');
    }

    final timestamps = (result['timestamp'] as List?)?.cast<num>() ?? const <num>[];
    final quote = ((result['indicators']?['quote']) as List?)?.firstOrNull as Map<String, dynamic>?;
    if (quote == null || timestamps.isEmpty) {
      throw DataServiceException('Yahoo Finance returned an empty series');
    }

    final opens = quote['open'] as List;
    final highs = quote['high'] as List;
    final lows = quote['low'] as List;
    final closes = quote['close'] as List;
    final volumes = quote['volume'] as List;

    final candles = <Candle>[];
    for (var i = 0; i < timestamps.length; i++) {
      if (opens[i] == null || highs[i] == null || lows[i] == null || closes[i] == null) {
        continue; // Yahoo pads market-closed gaps with nulls.
      }
      candles.add(Candle(
        time: DateTime.fromMillisecondsSinceEpoch(timestamps[i].toInt() * 1000, isUtc: true),
        open: (opens[i] as num).toDouble(),
        high: (highs[i] as num).toDouble(),
        low: (lows[i] as num).toDouble(),
        close: (closes[i] as num).toDouble(),
        volume: (volumes[i] as num?)?.toDouble() ?? 0,
      ));
    }
    if (candles.isEmpty) {
      throw DataServiceException('Yahoo Finance returned no usable candles');
    }

    final result0 = aggregateInto4h ? _aggregate4h(candles) : candles;
    return result0.length > count ? result0.sublist(result0.length - count) : result0;
  }

  /// Yahoo has no native 4H interval — 60m bars are bucketed by real UTC
  /// 4-hour boundaries (00/04/08/12/16/20), not by list position, so session
  /// gaps and missing hours can't shift every following 4H candle.
  List<Candle> _aggregate4h(List<Candle> source) {
    const bucketMs = 4 * 3600 * 1000;
    final buckets = <int, List<Candle>>{};
    for (final c in source) {
      final key = (c.time.millisecondsSinceEpoch ~/ bucketMs) * bucketMs;
      buckets.putIfAbsent(key, () => []).add(c);
    }
    final keys = buckets.keys.toList()..sort();
    final out = <Candle>[];
    for (final key in keys) {
      final chunk = buckets[key]!;
      out.add(Candle(
        time: DateTime.fromMillisecondsSinceEpoch(key, isUtc: true),
        open: chunk.first.open,
        high: chunk.map((c) => c.high).reduce(max),
        low: chunk.map((c) => c.low).reduce(min),
        close: chunk.last.close,
        volume: chunk.fold<double>(0.0, (s, c) => s + c.volume),
      ));
    }
    return out;
  }

  (String, String) _intervalAndRangeFor(int timeframeMinutes) {
    switch (timeframeMinutes) {
      case 1:
        return ('1m', '1d');
      case 5:
        return ('5m', '5d');
      case 15:
        return ('15m', '1mo');
      case 60:
        return ('60m', '3mo');
      case 240:
        return ('60m', '3mo'); // fetched hourly, then aggregated 4:1 above
      case 1440:
        return ('1d', '2y');
      default:
        return ('15m', '1mo');
    }
  }
}
