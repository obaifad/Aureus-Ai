import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import '../models/economic_event.dart';
import 'app_logger.dart';

/// High-impact USD economic calendar (CPI, NFP, FOMC, ...) from the public
/// ForexFactory weekly JSON export. That endpoint rate-limits aggressively,
/// so the feed is cached in SharedPreferences for [_cacheTtl] and shared by
/// both isolates; already-notified events are remembered so each alert
/// fires exactly once.
class NewsCalendarService {
  static const _feedUrl = 'https://nfs.faireconomy.media/ff_calendar_thisweek.json';
  static const _cacheKey = 'aureus_news_cache_v1';
  static const _cacheTimeKey = 'aureus_news_cache_time_v1';
  static const _notifiedKey = 'aureus_news_notified_v1';
  static const _cacheTtl = Duration(hours: 6);
  static const _failureRetry = Duration(minutes: 30);
  static const _advanceNotice = Duration(minutes: 15);

  static DateTime? _lastFailure;

  Future<List<EconomicEvent>> upcomingHighImpactUsd() async {
    if (AppConfig.useMockData) return const [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();

    String? raw = prefs.getString(_cacheKey);
    final cachedAtMs = prefs.getInt(_cacheTimeKey);
    final cacheAge = cachedAtMs == null
        ? null
        : DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(cachedAtMs));
    final canRetry = _lastFailure == null || DateTime.now().difference(_lastFailure!) > _failureRetry;

    if ((raw == null || cacheAge == null || cacheAge > _cacheTtl) && canRetry) {
      try {
        final response = await http
            .get(Uri.parse(_feedUrl), headers: {'User-Agent': 'AureusAI/1.0'})
            .timeout(const Duration(seconds: 10));
        if (response.statusCode == 200) {
          raw = response.body;
          await prefs.setString(_cacheKey, raw);
          await prefs.setInt(_cacheTimeKey, DateTime.now().millisecondsSinceEpoch);
          _lastFailure = null;
        } else {
          _lastFailure = DateTime.now();
          AppLogger.log('News calendar: feed returned ${response.statusCode} — using cached copy');
        }
      } catch (e) {
        _lastFailure = DateTime.now();
        AppLogger.log('News calendar: fetch failed ($e) — using cached copy');
      }
    }
    if (raw == null) return const [];

    try {
      final list = jsonDecode(raw) as List<dynamic>;
      final events = <EconomicEvent>[];
      for (final item in list) {
        final map = item as Map<String, dynamic>;
        if ((map['country'] as String?)?.toUpperCase() != 'USD') continue;
        if ((map['impact'] as String?)?.toLowerCase() != 'high') continue;
        final date = DateTime.tryParse(map['date'] as String? ?? '');
        if (date == null) continue;
        events.add(EconomicEvent(name: map['title'] as String? ?? 'USD event', timeUtc: date.toUtc()));
      }
      return events;
    } catch (e) {
      AppLogger.log('News calendar: could not parse feed: $e');
      return const [];
    }
  }

  /// Events starting within the next 15 minutes that haven't been announced.
  Future<List<EconomicEvent>> dueForAdvanceNotice() async {
    final events = await upcomingHighImpactUsd();
    if (events.isEmpty) return const [];

    final now = DateTime.now().toUtc();
    final due = events.where((e) {
      final untilEvent = e.timeUtc.difference(now);
      return untilEvent > Duration.zero && untilEvent <= _advanceNotice;
    }).toList();
    if (due.isEmpty) return const [];

    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final notified = (prefs.getStringList(_notifiedKey) ?? const <String>[]).toSet();
    String keyOf(EconomicEvent e) => '${e.name}@${e.timeUtc.toIso8601String()}';
    final fresh = due.where((e) => !notified.contains(keyOf(e))).toList();
    if (fresh.isEmpty) return const [];

    notified.addAll(fresh.map(keyOf));
    // Keep the list bounded — only recent keys matter.
    final trimmed = notified.length > 100 ? notified.skip(notified.length - 100).toList() : notified.toList();
    await prefs.setStringList(_notifiedKey, trimmed);
    for (final e in fresh) {
      AppLogger.log('📰 High-impact USD news in ${e.timeUtc.difference(now).inMinutes}m: ${e.name}');
    }
    return fresh;
  }
}
