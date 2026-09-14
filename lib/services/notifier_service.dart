import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../models/economic_event.dart';
import '../models/price_alert.dart';
import '../models/trade_setup.dart';
import 'app_logger.dart';

/// RECONSTRUCTED 2026-09-12 (the original file was lost — see chat for
/// context). Delivers every alert two ways:
///  1) a local push notification (flutter_local_notifications), and
///  2) an optional Telegram message (if a bot token + chat id are set —
///     see AppConfig.telegramBotToken/telegramChatId).
class NotifierService {
  static final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    _initialized = true;
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings();
    const settings = InitializationSettings(android: android, iOS: ios);
    try {
      await _plugin.initialize(settings);
    } catch (e) {
      AppLogger.log('NotifierService: local notification init failed: $e');
    }
  }

  Future<void> _showLocal(int id, String title, String body) async {
    await _ensureInitialized();
    const androidDetails = AndroidNotificationDetails(
      'aureus_alerts',
      'Aureus AI Alerts',
      channelDescription: 'Trade signals, outcomes, news, and price alerts.',
      importance: Importance.high,
      priority: Priority.high,
    );
    const details = NotificationDetails(android: androidDetails, iOS: DarwinNotificationDetails());
    try {
      await _plugin.show(id, title, body, details);
    } catch (e) {
      AppLogger.log('NotifierService: show() failed: $e');
    }
  }

  Future<void> sendSignal(TradeSetup setup) async {
    final title = '${setup.emoji} ${setup.setupLabel}';
    final body = 'Entry ${setup.entry} | SL ${setup.stopLoss} | TP ${setup.takeProfit} '
        '(R:R 1:${setup.riskRewardRatio.toStringAsFixed(1)}, Score ${setup.confluenceScore}/100)';
    await _showLocal(setup.notificationId(), title, body);
    await _sendTelegram(
      '$title\n$body\n${setup.aiReason}',
    );
  }

  Future<void> sendOutcome(TradeSetup setup) async {
    final title = '${setup.outcomeLabel ?? "Trade Closed"} — ${setup.setupLabel}';
    final pips = setup.pips;
    final body = 'Closed @ ${setup.closedPrice?.toStringAsFixed(2)}'
        '${pips == null ? "" : " (${pips >= 0 ? "+" : ""}${pips.toStringAsFixed(1)} pips)"}';
    await _showLocal(setup.notificationId(salt: 1), title, body);
    await _sendTelegram('$title\n$body');
  }

  Future<void> sendNewsAlert(EconomicEvent event) async {
    final title = '📰 High-Impact News in 15m: ${event.name}';
    final local = event.timeUtc.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    final body = '${event.currency} — at $hh:$mm (local time)';
    await _showLocal('${event.name}@${event.timeUtc.millisecondsSinceEpoch}'.hashCode & 0x3fffffff, title, body);
    await _sendTelegram('$title\n$body');
  }

  Future<void> sendPriceAlert(PriceAlert alert, double currentPrice) async {
    final title = '🔔 Price Alert: \$${alert.targetPrice.toStringAsFixed(2)}';
    final body = 'Current price: \$${currentPrice.toStringAsFixed(2)}';
    await _showLocal(alert.id.hashCode & 0x3fffffff, title, body);
    await _sendTelegram('$title\n$body');
  }

  Future<void> _sendTelegram(String text) async {
    if (AppConfig.telegramBotToken.isEmpty || AppConfig.telegramChatId.isEmpty) {
      return; // Telegram delivery is optional.
    }
    try {
      final uri = Uri.parse('https://api.telegram.org/bot${AppConfig.telegramBotToken}/sendMessage');
      final response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'chat_id': AppConfig.telegramChatId,
              'text': text,
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        AppLogger.log('NotifierService: Telegram returned ${response.statusCode}');
      }
    } catch (e) {
      AppLogger.log('NotifierService: Telegram send failed: $e');
    }
  }
}
