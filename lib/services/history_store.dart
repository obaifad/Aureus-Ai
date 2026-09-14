import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/trade_setup.dart';
import 'app_logger.dart';

/// Single access point for the persisted signal history.
///
/// SharedPreferences keeps a per-isolate in-memory cache, so a value written
/// by the foreground-service isolate is invisible to the UI isolate (and vice
/// versa) until [SharedPreferences.reload] — every read here reloads first.
/// Writes are serialized within an isolate by [_synchronized]; across
/// isolates there is exactly one writer at a time by design (the isolate
/// that currently runs [MonitorEngine]), the other only reads.
class HistoryStore {
  HistoryStore._();

  static const int maxPersisted = 200;

  static Future<void> _lock = Future.value();

  static Future<T> _synchronized<T>(Future<T> Function() action) {
    final previous = _lock;
    final done = Completer<void>();
    _lock = done.future;
    return previous.then((_) => action()).whenComplete(done.complete);
  }

  static Future<List<TradeSetup>> _read(SharedPreferences prefs) async {
    await prefs.reload();
    final raw = prefs.getStringList(TradeSetup.historyPrefsKey) ?? const <String>[];
    final setups = <TradeSetup>[];
    for (final entry in raw) {
      try {
        setups.add(TradeSetup.fromJson(jsonDecode(entry) as Map<String, dynamic>));
      } catch (e) {
        AppLogger.log('HistoryStore: skipped corrupt history entry ($e)');
      }
    }
    return setups;
  }

  static Future<List<TradeSetup>> load() => _synchronized(() async {
        try {
          return await _read(await SharedPreferences.getInstance());
        } catch (e) {
          AppLogger.log('HistoryStore: load failed: $e');
          return <TradeSetup>[];
        }
      });

  /// Reloads, lets [update] modify the list in place, and persists it only
  /// when [update] returns true. Returns the (possibly updated) list.
  static Future<List<TradeSetup>> mutate(FutureOr<bool> Function(List<TradeSetup> history) update) =>
      _synchronized(() async {
        final prefs = await SharedPreferences.getInstance();
        final history = await _read(prefs);
        if (await update(history)) {
          final toSave = history.take(maxPersisted).map((s) => jsonEncode(s.toJson())).toList();
          await prefs.setStringList(TradeSetup.historyPrefsKey, toSave);
        }
        return history;
      });
}
