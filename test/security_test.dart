import 'dart:convert';

import 'package:aureus_ai/config/app_config.dart';
import 'package:aureus_ai/models/pivot.dart';
import 'package:aureus_ai/models/trade_setup.dart';
import 'package:aureus_ai/services/notifier_service.dart';
import 'package:aureus_ai/services/tick_stream_service.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _bridge =
    'BRIDGE_BASE_URL=http://bridge.test\nBRIDGE_API_KEY=bridge-secret-key-0123456789\nDISABLE_MT5_BRIDGE=false\n';
const _live = 'USE_MOCK_DATA=false\n$_bridge';
// The secrets-in-the-bundle audit judges a bridge on this machine, where a leaked key is not
// enough to reach it from outside.
const _liveLocalBridge = 'USE_MOCK_DATA=false\nDISABLE_MT5_BRIDGE=false\n'
    'BRIDGE_BASE_URL=http://127.0.0.1:8000\nBRIDGE_API_KEY=bridge-secret-key-0123456789\n';

TradeSetup _setup() => TradeSetup(
      symbol: 'XAUUSD',
      direction: TradeDirection.buy,
      timeframeLabel: '15M',
      setupType: SetupType.rangingBounce,
      entry: 2400,
      stopLoss: 2390,
      takeProfit: 2418,
      pattern: CandlePattern.bullishPinbar,
      detectedAt: DateTime.utc(2026, 10, 2, 10),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('tick stream: the key never travels in the URL', () {
    test('the URL carries only the symbol, and wss follows https', () {
      final uri = TickStreamService.buildUri('http://127.0.0.1:8000', 'XAUUSD...');
      expect(uri.scheme, 'ws');
      expect(uri.path, '/stream/ticks');
      expect(uri.queryParameters, {'symbol': 'XAUUSD...'});
      expect(uri.toString(), isNot(contains('api_key')));
      expect(TickStreamService.buildUri('https://bridge.example', 'X').scheme, 'wss');
    });

    test('the key is sent as the first message', () {
      final message =
          jsonDecode(TickStreamService.authMessage('bridge-secret-key-0123456789')!) as Map<String, dynamic>;
      expect(message, {'type': 'auth', 'api_key': 'bridge-secret-key-0123456789'});
    });

    test('with no key configured nothing is sent', () {
      expect(TickStreamService.authMessage(''), isNull);
    });
  });

  group('secrets bundled inside the app', () {
    test('a clean app .env raises no warning', () {
      dotenv.testLoad(fileInput: _liveLocalBridge);
      expect(AppConfig.bundledSecretWarnings, isEmpty);
    });

    test('each secret that belongs on the bridge is called out by name', () {
      dotenv.testLoad(
        fileInput: '$_liveLocalBridge\nANTHROPIC_API_KEY=sk-ant-123\nTELEGRAM_BOT_TOKEN=1:abc\nTELEGRAM_CHAT_ID=5\n'
            'BRIDGE_ONLY=true\nTWELVE_DATA_API_KEY=td-key',
      );
      final text = AppConfig.bundledSecretWarnings.join('\n');
      expect(AppConfig.bundledSecretWarnings, hasLength(3));
      expect(text, contains('ANTHROPIC_API_KEY'));
      expect(text, contains('TELEGRAM_BOT_TOKEN'));
      expect(text, contains('TWELVE_DATA_API_KEY'));
    });

    test('the TwelveData key is only flagged when Bridge-Only makes it unused', () {
      dotenv.testLoad(fileInput: '$_liveLocalBridge\nBRIDGE_ONLY=false\nTWELVE_DATA_API_KEY=td-key');
      expect(AppConfig.bundledSecretWarnings, isEmpty);
    });

    test('warnings never contain the secret values themselves', () {
      dotenv.testLoad(
          fileInput: '$_liveLocalBridge\nANTHROPIC_API_KEY=sk-ant-VERYSECRET\nTELEGRAM_BOT_TOKEN=9:TOKENVALUE');
      final text = AppConfig.bundledSecretWarnings.join('\n');
      expect(text, isNot(contains('VERYSECRET')));
      expect(text, isNot(contains('TOKENVALUE')));
    });

    test('standalone and mock mode have no bridge to move secrets to, so they stay quiet', () {
      dotenv.testLoad(fileInput: 'USE_MOCK_DATA=true\nANTHROPIC_API_KEY=x\nTELEGRAM_BOT_TOKEN=y');
      expect(AppConfig.bundledSecretWarnings, isEmpty);
      dotenv.testLoad(fileInput: 'USE_MOCK_DATA=false\nDISABLE_MT5_BRIDGE=true\nANTHROPIC_API_KEY=x');
      expect(AppConfig.bundledSecretWarnings, isEmpty);
    });
  });

  group('Telegram goes through the bridge', () {
    late List<http.Request> requests;
    Map<String, dynamic> bridgeReply = {'sent': true};
    int bridgeStatus = 200;
    bool bridgeDown = false;

    setUp(() {
      requests = [];
      bridgeReply = {'sent': true};
      bridgeStatus = 200;
      bridgeDown = false;
    });

    Future<void> send(String env) {
      dotenv.testLoad(fileInput: env);
      final client = MockClient((request) async {
        requests.add(request);
        if (request.url.host == 'bridge.test') {
          if (bridgeDown) throw Exception('connection refused');
          return http.Response(jsonEncode(bridgeReply), bridgeStatus);
        }
        return http.Response('{"ok":true}', 200); // api.telegram.org
      });
      return http.runWithClient(() => NotifierService().sendSignal(_setup()), () => client);
    }

    Iterable<http.Request> toBridge() => requests.where((r) => r.url.host == 'bridge.test');
    Iterable<http.Request> direct() => requests.where((r) => r.url.host == 'api.telegram.org');

    test('with a live bridge the alert is posted to /notify with the API key — and nowhere else', () async {
      await send(_live);
      expect(toBridge(), hasLength(1));
      final request = toBridge().single;
      expect(request.url.path, '/notify');
      expect(request.headers['X-API-Key'], 'bridge-secret-key-0123456789');
      expect(jsonDecode(request.body)['text'], contains('Entry'));
      expect(direct(), isEmpty);
    });

    test('a token left in the app .env is NOT used while the bridge delivers', () async {
      await send('$_live\nTELEGRAM_BOT_TOKEN=1:abc\nTELEGRAM_CHAT_ID=5');
      expect(direct(), isEmpty);
    });

    test('migration: if the bridge has no token yet, the app\'s own one is used as a fallback', () async {
      bridgeReply = {'sent': false, 'reason': 'telegram_not_configured'};
      await send('$_live\nTELEGRAM_BOT_TOKEN=1:abc\nTELEGRAM_CHAT_ID=5');
      expect(direct(), hasLength(1));
      expect(direct().single.url.path, '/bot1:abc/sendMessage');
    });

    test('with no token anywhere, nothing more is attempted', () async {
      bridgeReply = {'sent': false, 'reason': 'telegram_not_configured'};
      await send(_live);
      expect(direct(), isEmpty);
    });

    test('a bridge that is down or erroring does not make the app fall back to its bundled token', () async {
      bridgeDown = true;
      await send('$_live\nTELEGRAM_BOT_TOKEN=1:abc\nTELEGRAM_CHAT_ID=5');
      expect(direct(), isEmpty);
      requests.clear();
      bridgeDown = false;
      bridgeStatus = 500;
      await send('$_live\nTELEGRAM_BOT_TOKEN=1:abc\nTELEGRAM_CHAT_ID=5');
      expect(direct(), isEmpty);
    });

    test('a Telegram-side failure reported by the bridge is not retried directly', () async {
      bridgeReply = {'sent': false, 'reason': 'telegram_http_401'};
      await send('$_live\nTELEGRAM_BOT_TOKEN=1:abc\nTELEGRAM_CHAT_ID=5');
      expect(direct(), isEmpty);
    });

    test('standalone mode (no bridge) still sends directly when a token is set', () async {
      await send('USE_MOCK_DATA=false\nDISABLE_MT5_BRIDGE=true\nTELEGRAM_BOT_TOKEN=1:abc\nTELEGRAM_CHAT_ID=5');
      expect(toBridge(), isEmpty);
      expect(direct(), hasLength(1));
    });

    test('with no token and no bridge nothing is sent at all', () async {
      await send('USE_MOCK_DATA=true');
      expect(requests, isEmpty);
    });
  });
}
