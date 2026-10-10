import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../models/economic_event.dart';
import '../models/pivot.dart' show TradeOutcome;
import '../models/price_alert.dart';
import '../models/trade_setup.dart';
import 'app_logger.dart';
import 'data_service.dart' show bridgeHeaders;

/// RECONSTRUCTED 2026-09-12 (the original file was lost — see chat for
/// context). Delivers every alert two ways:
///  1) a local push notification (flutter_local_notifications), and
///  2) an optional Telegram message (if a bot token + chat id are set —
///     see AppConfig.telegramBotToken/telegramChatId).
class NotifierService {
  static final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  /// Windows never showed (or sounded) a notification at all before
  /// 2026-09-15 — this package's Windows platform support didn't exist
  /// until v19.3.0 (this project was pinned to ^17.2.2), so on desktop
  /// [_plugin.initialize] had nothing to actually initialize. The GUID is
  /// this app's own fixed identity (arbitrary but stable — generated once,
  /// never changes) that Windows uses to register the Toast notification
  /// source; unlike [iconPath] (native code reads it directly off disk, not
  /// through Flutter's asset bundle, so a build-time-relative path would
  /// break once the app is installed/copied elsewhere) it's left unset —
  /// Windows just shows the app's own default icon instead.
  static const _windows = WindowsInitializationSettings(
    appName: 'Aureus AI',
    appUserModelId: 'Com.AureusAI.TradingAssistant',
    guid: '561cb069-356a-4009-8a31-fc467a96298d',
  );

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    _initialized = true;
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings();
    const settings = InitializationSettings(android: android, iOS: ios, windows: _windows);
    try {
      await _plugin.initialize(settings: settings);
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
    const details = NotificationDetails(
      android: androidDetails,
      iOS: DarwinNotificationDetails(),
      windows: WindowsNotificationDetails(),
    );
    try {
      await _plugin.show(id: id, title: title, body: body, notificationDetails: details);
    } catch (e) {
      AppLogger.log('NotifierService: show() failed: $e');
    }
  }

  /// [telegram] false: used for a trade the owner approved ON Telegram, where the
  /// bridge has already messaged them — only the local notification is shown.
  ///
  /// Telegram goes out BEFORE the local notification, in every method here (2026-10-09): the Windows toast is
  /// native code, and on 2026-10-08 it took the whole app down 0.2 s after a trade opened — before the Telegram
  /// message for that trade was sent, so it was never delivered. Telegram is the alert that reaches the owner
  /// away from the PC, so nothing local may stand in front of it.
  Future<void> sendSignal(TradeSetup setup, {bool telegram = true}) async {
    final title = '${setup.emoji} ${setup.setupLabel}';
    final body = 'Entry ${setup.entry} | SL ${setup.stopLoss} | TP ${setup.takeProfit} '
        '(R:R 1:${setup.riskRewardRatio.toStringAsFixed(1)}, Score ${setup.confluenceScore}/100)';
    if (telegram) {
      await _sendTelegram(
        '$title\n$body\n${setup.aiReason}',
      );
    }
    await _showLocal(setup.notificationId(), title, body);
  }

  Future<void> sendOutcome(TradeSetup setup) async {
    if (setup.isMissed) return _sendMissedOutcome(setup);
    final title = '${setup.outcomeLabel ?? "Trade Closed"} — ${setup.setupLabel}';
    final pips = setup.pips;
    // A trade backed by a real MT5 position also reports what the broker booked and why it closed.
    final broker = [
      if (setup.brokerProfitLabel != null) 'MT5 net ${setup.brokerProfitLabel}',
      if (setup.closeReasonLabel != null) setup.closeReasonLabel!,
    ];
    final body = 'Closed @ ${setup.closedPrice?.toStringAsFixed(2)}'
        '${pips == null ? "" : " (${pips >= 0 ? "+" : ""}${pips.toStringAsFixed(1)} pips)"}'
        '${broker.isEmpty ? "" : "\n${broker.join(" · ")}"}';
    await _sendTelegram('$title\n$body');
    await _showLocal(setup.notificationId(salt: 1), title, body);
  }

  /// What a signal nobody traded went on to do — clearly labelled so it is never mistaken for a real result.
  /// Telegram gets it unless you rejected the signal yourself (a decision you already know the answer to).
  Future<void> _sendMissedOutcome(TradeSetup setup) async {
    final won = setup.outcome == TradeOutcome.win;
    final pips = setup.pips;
    final title = '${won ? "📭 Missed a winner" : "✅ Avoided a loss"} — ${setup.setupLabel}';
    final body = 'Not traded (${setup.notTradedLabel ?? "no trade"}). It ${won ? "would have hit TP" : "hit SL"}'
        ' @ ${setup.closedPrice?.toStringAsFixed(2)}'
        '${pips == null ? "" : " (${pips >= 0 ? "+" : ""}${pips.toStringAsFixed(1)} pips)"}.';
    if (setup.notTradedReason != 'rejected') await _sendTelegram('$title\n$body');
    await _showLocal(setup.notificationId(salt: 1), title, body);
  }

  Future<void> sendNewsAlert(EconomicEvent event) async {
    final title = '📰 High-Impact News in 15m: ${event.name}';
    final local = event.timeUtc.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    final body = '${event.currency} — at $hh:$mm (local time)';
    await _sendTelegram('$title\n$body');
    await _showLocal('${event.name}@${event.timeUtc.millisecondsSinceEpoch}'.hashCode & 0x3fffffff, title, body);
  }

  Future<void> sendPriceAlert(PriceAlert alert, double currentPrice) async {
    final title = '🔔 Price Alert: \$${alert.targetPrice.toStringAsFixed(2)}';
    final body = 'Current price: \$${currentPrice.toStringAsFixed(2)}';
    await _sendTelegram('$title\n$body');
    await _showLocal(alert.id.hashCode & 0x3fffffff, title, body);
  }

  static bool _warnedDirectTelegram = false;

  /// With a live bridge, alerts go THROUGH it (`POST /notify`): the bot token
  /// then lives only in bridge/.env instead of inside the app bundle. Direct
  /// sending from the app remains only for standalone/mock mode, and as a
  /// migration fallback while the bridge has no token configured yet.
  Future<void> _sendTelegram(String text) async {
    final viaBridge = !AppConfig.useMockData && !AppConfig.disableMt5Bridge;
    if (viaBridge) {
      final reason = await _sendViaBridge(text);
      if (reason != 'telegram_not_configured') return;
      if (AppConfig.telegramBotToken.isEmpty || AppConfig.telegramChatId.isEmpty) return;
      if (!_warnedDirectTelegram) {
        _warnedDirectTelegram = true;
        AppLogger.log('SECURITY: Telegram is sending directly from the app because the bridge has no '
            'TELEGRAM_BOT_TOKEN. Move the token (and chat id) into bridge/.env and delete them from the app .env.');
      }
    }
    await _sendDirect(text);
  }

  /// Returns null when delivered, otherwise the reason it was not.
  Future<String?> _sendViaBridge(String text) async {
    try {
      final response = await http
          .post(
            Uri.parse('${AppConfig.bridgeBaseUrl}/notify'),
            headers: {...bridgeHeaders(), 'Content-Type': 'application/json'},
            body: jsonEncode({'text': text}),
          )
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) {
        AppLogger.log('NotifierService: bridge /notify returned ${response.statusCode}');
        return 'http_${response.statusCode}';
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (data['sent'] == true) return null;
      final reason = data['reason']?.toString() ?? 'not_sent';
      if (reason != 'telegram_not_configured') AppLogger.log('NotifierService: Telegram not delivered ($reason)');
      return reason;
    } catch (e) {
      AppLogger.log('NotifierService: bridge /notify failed: $e');
      return 'unreachable';
    }
  }

  Future<void> _sendDirect(String text) async {
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
