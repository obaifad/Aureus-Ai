import 'dart:convert';

import 'package:aureus_ai/services/data_service.dart';
import 'package:aureus_ai/services/mt5_trading_service.dart';
import 'package:aureus_ai/services/signal_checker.dart';
import 'package:aureus_ai/services/strategy_config_service.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _status({
  bool available = true,
  bool locked = false,
  double loss = 1.0,
  int overrides = 0,
  String onBreach = 'block',
}) =>
    {
      'available': available,
      'locked': locked,
      'limit_percent': 3.0,
      'loss_percent': loss,
      'locked_loss_percent': locked ? loss : null,
      'equity': 9900.0,
      'baseline': 10000.0,
      'baseline_source': 'deals',
      'overrides_today': overrides,
      'on_breach': onBreach,
    };

http.Response _json(Object body, [int status = 200]) => http.Response(jsonEncode(body), status);

void main() {
  late List<http.Request> requests;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    StrategyConfig.instance.resetForTesting();
    dotenv.testLoad(
      fileInput:
          'USE_MOCK_DATA=false\nDISABLE_MT5_BRIDGE=false\nBRIDGE_BASE_URL=http://bridge.test\nRECONCILE_WITH_BROKER=false',
    );
    requests = [];
  });
  tearDown(() => StrategyConfig.instance.resetForTesting());

  Mt5TradingService trading(http.Response Function(http.Request) handler) => Mt5TradingService(
        client: MockClient((request) async {
          requests.add(request);
          return handler(request);
        }),
      );

  group('RiskStatus', () {
    test('parses the bridge payload', () {
      final s = RiskStatus.fromJson(_status(locked: true, loss: 3.2, onBreach: 'close_all'));
      expect((s.available, s.locked, s.limitPercent, s.lossPercent), (true, true, 3.0, 3.2));
      expect((s.equity, s.baseline, s.baselineSource, s.onBreach), (9900.0, 10000.0, 'deals', 'close_all'));
      expect(s.lockedLossPercent, 3.2);
    });

    test('an override is offered only while locked and unused', () {
      expect(RiskStatus.fromJson(_status()).canOverride, isFalse);
      expect(RiskStatus.fromJson(_status(locked: true)).canOverride, isTrue);
      expect(RiskStatus.fromJson(_status(locked: true, overrides: 1)).canOverride, isFalse);
    });

    test('tolerates the minimal payload sent when equity is unreadable', () {
      final s = RiskStatus.fromJson({'available': false, 'locked': false, 'limit_percent': 3.0});
      expect(s.available, isFalse);
      expect(s.lossPercent, isNull);
      expect(s.onBreach, 'block');
    });
  });

  group('Mt5TradingService risk calls', () {
    test('getRiskStatus reads /risk/status', () async {
      final s = await trading((_) => _json(_status(locked: true))).getRiskStatus();
      expect(s?.locked, isTrue);
      expect(requests.single.url.path, '/risk/status');
    });

    test('returns null on an error status, a bad payload or no connection', () async {
      expect(await trading((_) => http.Response('no', 503)).getRiskStatus(), isNull);
      expect(await trading((_) => http.Response('not json', 200)).getRiskStatus(), isNull);
      final broken = Mt5TradingService(client: MockClient((_) async => throw Exception('refused')));
      expect(await broken.getRiskStatus(), isNull);
    });

    test('mock / standalone mode never calls the bridge', () async {
      dotenv.testLoad(fileInput: 'USE_MOCK_DATA=true');
      expect(await trading((_) => _json(_status())).getRiskStatus(), isNull);
      expect(requests, isEmpty);
    });

    test('overrideDailyLoss always sends confirm=true and reports success', () async {
      final r = await trading((_) => _json(_status())).overrideDailyLoss();
      expect(r.ok, isTrue);
      expect(requests.single.url.path, '/risk/override');
      expect(jsonDecode(requests.single.body)['confirm'], isTrue);
    });

    test('a refused override carries the bridge\'s reason', () async {
      final r = await trading((_) => _json({
            'detail': {'code': 'override_not_allowed', 'message': 'The daily-loss override was already used today.'}
          }, 429)).overrideDailyLoss();
      expect(r.ok, isFalse);
      expect(r.message, contains('already used today'));
    });
  });

  group('SignalChecker honours the lock', () {
    http.Response bridge(http.Request request, {required Object risk}) {
      switch (request.url.path) {
        case '/risk/status':
          return risk is Exception ? throw risk : _json(risk);
        case '/reconcile':
          return _json({'positions': [], 'closed': [], 'history_ok': true});
      }
      return http.Response('not found', 404); // /config, the news feed, anything else
    }

    Future<SignalCheckResult> scan(Object risk) {
      final client = MockClient((request) async {
        requests.add(request);
        return bridge(request, risk: risk);
      });
      return http.runWithClient(
        () => SignalChecker(dataServiceFactory: () => MockDataService()).check(),
        () => client,
      );
    }

    test('a locked account generates no signals and says why', () async {
      final result = await scan(_status(locked: true, loss: 3.1));
      expect(result.setups, isEmpty);
      expect(result.status, contains('Daily loss limit reached'));
      expect(result.status, contains('3.10%'));
      expect(result.status, contains('00:00 UTC'));
    });

    test('an unlocked account scans normally', () async {
      final result = await scan(_status(loss: 0.4));
      expect(result.status, isNot(contains('Daily loss limit reached')));
      expect(requests.any((r) => r.url.path == '/risk/status'), isTrue);
    });

    test('an unreachable risk endpoint does not stop signals (the bridge still refuses orders itself)', () async {
      final result = await scan(Exception('connection refused'));
      expect(result.status, isNot(contains('Daily loss limit reached')));
    });
  });
}
