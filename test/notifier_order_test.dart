import 'dart:convert';

import 'package:aureus_ai/models/pivot.dart';
import 'package:aureus_ai/models/trade_setup.dart';
import 'package:aureus_ai/services/notifier_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 2026-10-09: on 2026-10-08 the Windows toast (native code) took the app down 0.2 s after a trade opened,
/// before that trade's Telegram message was sent. Telegram must now go out first, and a failing local
/// notification must never stop it.
const _live = 'USE_MOCK_DATA=false\nBRIDGE_BASE_URL=http://bridge.test\n'
    'BRIDGE_API_KEY=bridge-secret-key-0123456789\nDISABLE_MT5_BRIDGE=false\n';
const _channel = MethodChannel('dexterous.com/flutter/local_notifications');

TradeSetup _setup() => TradeSetup(
      symbol: 'XAUUSD',
      direction: TradeDirection.buy,
      timeframeLabel: '15M',
      setupType: SetupType.rangingBounce,
      entry: 2400,
      stopLoss: 2390,
      takeProfit: 2418,
      pattern: CandlePattern.bullishPinbar,
      confluenceScore: 80,
      aiReason: 'test',
      detectedAt: DateTime.utc(2026, 10, 8, 20),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<String> events;
  late bool localFails;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    dotenv.testLoad(fileInput: _live);
    // Unit tests run as Android with no plugin registrant: register the Android implementation so the local
    // notification really reaches its method channel, where the handler below records it.
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    events = [];
    localFails = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      if (call.method == 'show') {
        events.add('local');
        if (localFails) throw PlatformException(code: 'error', message: '0x803E0105 platform unavailable');
      }
      return call.method == 'initialize' ? true : null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
  });

  Future<void> run(Future<void> Function() body) {
    final client = MockClient((request) async {
      if (request.url.path == '/notify') events.add('telegram');
      return http.Response(jsonEncode({'sent': true}), 200);
    });
    return http.runWithClient(body, () => client);
  }

  test('a new trade: Telegram is sent before the local notification', () async {
    await run(() => NotifierService().sendSignal(_setup()));
    expect(events, ['telegram', 'local']);
  });

  test('a closed trade: Telegram is sent before the local notification', () async {
    final setup = _setup()
      ..outcome = TradeOutcome.win
      ..closedPrice = 2418
      ..closedAt = DateTime.utc(2026, 10, 9);
    await run(() => NotifierService().sendOutcome(setup));
    expect(events, ['telegram', 'local']);
  });

  test('a failing local notification neither stops Telegram nor throws', () async {
    localFails = true;
    await run(() => NotifierService().sendSignal(_setup()));
    expect(events, ['telegram', 'local']);
  });

  test('a trade approved on Telegram (telegram: false) still shows the local notification only', () async {
    await run(() => NotifierService().sendSignal(_setup(), telegram: false));
    expect(events, ['local']);
  });
}
