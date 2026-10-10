import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/trade_setup.dart';
import 'app_logger.dart';

/// A proposed trade waiting for the owner's Telegram decision. It lives
/// here — NOT in the trade history — until the bridge reports it decided:
/// a trade nobody has approved must not be tracked, scored or counted as a
/// position. Executed -> a real position in the history. Rejected, expired,
/// blocked or failed -> a flagged not-traded signal (TradeSetup.isMissed).
class PendingApproval {
  final TradeSetup setup;
  final String engineId;
  final DateTime submittedAt;
  final DateTime expiresAt;

  const PendingApproval({
    required this.setup,
    required this.engineId,
    required this.submittedAt,
    required this.expiresAt,
  });

  String get uid => setup.uid;

  Map<String, dynamic> toJson() => {
        'setup': setup.toJson(),
        'engine_id': engineId,
        'submitted_at': submittedAt.toUtc().toIso8601String(),
        'expires_at': expiresAt.toUtc().toIso8601String(),
      };

  factory PendingApproval.fromJson(Map<String, dynamic> json) => PendingApproval(
        setup: TradeSetup.fromJson((json['setup'] as Map).cast<String, dynamic>()),
        engineId: json['engine_id'] as String,
        submittedAt: DateTime.parse(json['submitted_at'] as String),
        expiresAt: DateTime.parse(json['expires_at'] as String),
      );
}

/// Persisted list of [PendingApproval]s. Same reload-then-write discipline as
/// HistoryStore, so the foreground-service isolate and the UI isolate always
/// see each other's writes.
class PendingStore {
  PendingStore._();

  static const prefsKey = 'aureus_pending_approvals_v1';

  static Future<void> _lock = Future.value();

  static Future<T> _synchronized<T>(Future<T> Function() action) {
    final previous = _lock;
    final done = Completer<void>();
    _lock = done.future;
    return previous.then((_) => action()).whenComplete(done.complete);
  }

  static Future<List<PendingApproval>> _read(SharedPreferences prefs) async {
    await prefs.reload();
    final out = <PendingApproval>[];
    for (final raw in prefs.getStringList(prefsKey) ?? const <String>[]) {
      try {
        out.add(PendingApproval.fromJson(jsonDecode(raw) as Map<String, dynamic>));
      } catch (e) {
        AppLogger.log('PendingStore: skipped an unreadable entry ($e)');
      }
    }
    return out;
  }

  static Future<void> _write(SharedPreferences prefs, List<PendingApproval> items) =>
      prefs.setStringList(prefsKey, [for (final p in items) jsonEncode(p.toJson())]);

  static Future<List<PendingApproval>> load() => _synchronized(() async {
        try {
          return await _read(await SharedPreferences.getInstance());
        } catch (e) {
          AppLogger.log('PendingStore: load failed: $e');
          return <PendingApproval>[];
        }
      });

  static Future<void> add(PendingApproval approval) => _synchronized(() async {
        final prefs = await SharedPreferences.getInstance();
        final items = await _read(prefs);
        items.removeWhere((p) => p.uid == approval.uid);
        items.add(approval);
        await _write(prefs, items);
      });

  static Future<void> remove(String uid) => _synchronized(() async {
        final prefs = await SharedPreferences.getInstance();
        final items = await _read(prefs);
        final before = items.length;
        items.removeWhere((p) => p.uid == uid);
        if (items.length != before) await _write(prefs, items);
      });
}
