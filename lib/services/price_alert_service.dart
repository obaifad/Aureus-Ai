import 'dart:convert';
import 'package:collection/collection.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/price_alert.dart';

/// RECONSTRUCTED 2026-09-12 (the original file was lost — see chat for
/// context), now backing AlertsScreen's full add/toggle/remove UI.
class PriceAlertService {
  static const _prefsKey = 'aureus_price_alerts_v1';

  Future<List<PriceAlert>> getAlerts() async {
    final prefs = await SharedPreferences.getInstance();
    // Alerts are added in the UI isolate but checked in the foreground-
    // service isolate — reload so each side sees the other's writes.
    await prefs.reload();
    final raw = prefs.getStringList(_prefsKey) ?? const [];
    return raw.map((s) => PriceAlert.fromJson(jsonDecode(s) as Map<String, dynamic>)).toList();
  }

  Future<void> addAlert({required double targetPrice, required bool triggerAbove}) async {
    final alerts = await getAlerts();
    alerts.add(PriceAlert(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      targetPrice: targetPrice,
      triggerAbove: triggerAbove,
    ));
    await _persist(alerts);
  }

  Future<void> removeAlert(String id) async {
    final alerts = await getAlerts();
    alerts.removeWhere((a) => a.id == id);
    await _persist(alerts);
  }

  /// AlertsScreen's on/off Switch — a disabled alert is skipped by
  /// [checkAndTrigger] entirely (not deleted, so it keeps its
  /// [PriceAlert.triggered] history if re-enabled later).
  Future<void> setEnabled(String id, bool enabled) async {
    final alerts = await getAlerts();
    final alert = alerts.where((a) => a.id == id).firstOrNull;
    if (alert == null) return;
    alert.enabled = enabled;
    await _persist(alerts);
  }

  /// Checks every enabled, un-triggered alert against [livePrice], marks
  /// any that just crossed as triggered (once — never fires the same
  /// alert twice), persists the change, and returns the ones that fired
  /// THIS call.
  Future<List<PriceAlert>> checkAndTrigger(double livePrice) async {
    final alerts = await getAlerts();
    final fired = <PriceAlert>[];
    for (final alert in alerts) {
      if (alert.triggered || !alert.enabled) continue;
      final crossed = alert.triggerAbove ? livePrice >= alert.targetPrice : livePrice <= alert.targetPrice;
      if (crossed) {
        alert.triggered = true;
        fired.add(alert);
      }
    }
    if (fired.isNotEmpty) await _persist(alerts);
    return fired;
  }

  Future<void> _persist(List<PriceAlert> alerts) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsKey, alerts.map((a) => jsonEncode(a.toJson())).toList());
  }
}
