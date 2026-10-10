import 'dart:convert';

import 'package:aureus_ai/config/app_config.dart';
import 'package:aureus_ai/models/pivot.dart';
import 'package:aureus_ai/models/trade_setup.dart';
import 'package:aureus_ai/services/signal_checker.dart';
import 'package:aureus_ai/services/strategy_config_service.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _config({
  String updatedBy = 'app',
  bool paused = false,
  Map<String, bool> enabled = const {},
  Map<String, String> dxy = const {},
  Map<String, double?> spread = const {},
}) =>
    {
      'updated_by': updatedBy,
      'mode': {'paused': paused, 'auto_trade': 'off'},
      'account_limits': {'risk_percent_per_trade': 0.5, 'max_spread_pips': 12.0},
      'trade_rules': {'one_active_trade': false},
      'filters': {
        'dxy': {'enabled': false},
      },
      'engines': {
        for (final id in EngineIds.all)
          id: {
            'enabled': enabled[id] ?? true,
            'dxy': dxy[id] ?? 'block',
            'max_spread_pips': spread[id],
          },
      },
    };

Map<String, dynamic> _body(int revision, Map<String, dynamic> config, {Map<String, dynamic>? bounds}) => {
      'config': config,
      'revision': revision,
      'bounds': bounds ?? <String, dynamic>{},
    };

StrategyConfigSnapshot _snap(int revision, Map<String, dynamic> config) =>
    StrategyConfigSnapshot.fromResponse(_body(revision, config));

void _liveEnv([String extra = '']) => dotenv.testLoad(
      fileInput: 'USE_MOCK_DATA=false\nDISABLE_MT5_BRIDGE=false\nBRIDGE_BASE_URL=http://bridge.test\n$extra',
    );

void main() {
  setUp(() {
    // The one-time engine-threshold move has its own group below; everywhere else it must not
    // add requests, so it starts out marked as done.
    SharedPreferences.setMockInitialValues({'aureus_engine_params_seeded_v1': true});
    StrategyConfig.instance.resetForTesting();
  });
  tearDown(() => StrategyConfig.instance.resetForTesting());

  group('AppConfig routing', () {
    test('with no bridge config every value falls back to .env / defaults', () {
      dotenv.testLoad(
        fileInput: 'USE_MOCK_DATA=true\nUSE_ORB=true\nUSE_BREAKOUT_MOMENTUM=false\nRISK_PERCENT_PER_TRADE=1.5\n'
            'MAX_SPREAD_PIPS=33\nONE_ACTIVE_TRADE_LIMIT=true\nUSE_DXY_FILTER=true',
      );
      expect(StrategyConfig.instance.current.isEmpty, isTrue);
      expect(AppConfig.useOrb, isTrue);
      expect(AppConfig.useBreakoutMomentum, isFalse);
      expect(AppConfig.riskPercentPerTrade, 1.5);
      expect(AppConfig.maxSpreadPips, 33);
      expect(AppConfig.oneActiveTradeLimit, isTrue);
      expect(AppConfig.useDxyFilter, isTrue);
      expect(AppConfig.useHtfRetest && AppConfig.useIct && AppConfig.useIci, isTrue);
    });

    test('the bridge config overrides .env once it is active', () {
      dotenv.testLoad(
        fileInput: 'USE_MOCK_DATA=true\nUSE_ORB=true\nRISK_PERCENT_PER_TRADE=1.5\nMAX_SPREAD_PIPS=33\n'
            'ONE_ACTIVE_TRADE_LIMIT=true\nUSE_DXY_FILTER=true',
      );
      StrategyConfig.instance.setSnapshot(
        _snap(5, _config(enabled: {EngineIds.orb: false, EngineIds.ict: false, EngineIds.rangeBounce: true})),
      );
      expect(AppConfig.useOrb, isFalse);
      expect(AppConfig.useIct, isFalse);
      expect(AppConfig.enableRangingBounceMode, isTrue); // .env says false/absent, config says on
      expect(AppConfig.riskPercentPerTrade, 0.5);
      expect(AppConfig.maxSpreadPips, 12);
      expect(AppConfig.oneActiveTradeLimit, isFalse);
      expect(AppConfig.useDxyFilter, isFalse);
    });

    test('per-engine accessors: dxy mode and spread override', () {
      final snap = _snap(
        3,
        _config(dxy: {EngineIds.rangeBounce: 'exempt'}, spread: {EngineIds.orb: 8}),
      );
      expect(snap.engineDxyMode(EngineIds.rangeBounce), 'exempt');
      expect(snap.engineDxyMode(EngineIds.orb), 'block');
      expect(snap.engineMaxSpreadPips(EngineIds.orb), 8);
      expect(snap.engineMaxSpreadPips(EngineIds.ict), isNull);
      expect(StrategyConfigSnapshot.empty.engineDxyMode(EngineIds.orb), isNull);
    });

    test('every strategy family maps to exactly one engine id', () {
      final ids = StrategyFamily.values.map(EngineIds.forFamily).toSet();
      expect(ids, EngineIds.all.toSet());
    });
  });

  group('refresh / beginCycle', () {
    test('a fetched config only becomes current at the next cycle boundary', () async {
      _liveEnv();
      final client = MockClient((request) async {
        return http.Response(jsonEncode(_body(2, _config(paused: true))), 200, headers: {'etag': '"2"'});
      });
      await StrategyConfig.instance.refresh(client: client);
      expect(StrategyConfig.instance.current.isEmpty, isTrue, reason: 'must not change mid-cycle');
      expect(StrategyConfig.instance.pending?.revision, 2);
      final promoted = StrategyConfig.instance.beginCycle();
      expect(promoted.revision, 2);
      expect(promoted.paused, isTrue);
      expect(StrategyConfig.instance.pending, isNull);
    });

    test('sends If-None-Match and treats 304 as unchanged', () async {
      _liveEnv();
      final seen = <String?>[];
      var calls = 0;
      final client = MockClient((request) async {
        seen.add(request.headers['If-None-Match']);
        calls++;
        if (calls == 1) {
          return http.Response(jsonEncode(_body(4, _config())), 200, headers: {'etag': '"4"'});
        }
        return http.Response('', 304);
      });
      await StrategyConfig.instance.refresh(client: client);
      StrategyConfig.instance.beginCycle();
      await StrategyConfig.instance.refresh(client: client);
      expect(seen, [null, '"4"']);
      expect(StrategyConfig.instance.current.revision, 4);
      expect(StrategyConfig.instance.pending, isNull);
    });

    test('an unreachable or erroring bridge keeps the last good config and never throws', () async {
      _liveEnv();
      StrategyConfig.instance.setSnapshot(_snap(6, _config(paused: true)));
      await StrategyConfig.instance.refresh(client: MockClient((_) async => throw Exception('connection refused')));
      await StrategyConfig.instance.refresh(client: MockClient((_) async => http.Response('boom', 500)));
      await StrategyConfig.instance.refresh(client: MockClient((_) async => http.Response('not json', 200)));
      expect(StrategyConfig.instance.beginCycle().revision, 6);
    });

    test('mock / standalone mode never touches the network', () async {
      dotenv.testLoad(fileInput: 'USE_MOCK_DATA=true');
      var calls = 0;
      await StrategyConfig.instance.refresh(client: MockClient((_) async {
        calls++;
        return http.Response('{}', 200);
      }));
      expect(calls, 0);
      dotenv.testLoad(fileInput: 'USE_MOCK_DATA=false\nDISABLE_MT5_BRIDGE=true');
      await StrategyConfig.instance.refresh(client: MockClient((_) async {
        calls++;
        return http.Response('{}', 200);
      }));
      expect(calls, 0);
    });

    test('the last good config survives a restart through SharedPreferences', () async {
      _liveEnv();
      await StrategyConfig.instance.refresh(
        client: MockClient((_) async => http.Response(jsonEncode(_body(9, _config(paused: true))), 200)),
      );
      StrategyConfig.instance.resetForTesting(); // simulates a fresh process
      expect(StrategyConfig.instance.current.isEmpty, isTrue);
      await StrategyConfig.instance.loadCache();
      expect(StrategyConfig.instance.current.revision, 9);
      expect(StrategyConfig.instance.current.paused, isTrue);
    });
  });

  group('first-run seeding from .env', () {
    test('a pristine bridge config is seeded with the current .env values, clamped to its bounds', () async {
      _liveEnv(
        'USE_ORB=true\nUSE_BREAKOUT_MOMENTUM=true\nENABLE_RANGING_BOUNCE=true\nUSE_DXY_FILTER=true\n'
        'RISK_PERCENT_PER_TRADE=1.0\nMAX_SPREAD_PIPS=99\nONE_ACTIVE_TRADE_LIMIT=true\nBREAKOUT_DXY_MODE=off',
      );
      final posts = <Map<String, dynamic>>[];
      final bounds = {
        'account_limits.max_spread_pips': {'type': 'float', 'min': 1.0, 'max': 60.0},
        'account_limits.risk_percent_per_trade': {'type': 'float', 'min': 0.05, 'max': 2.0},
      };
      final client = MockClient((request) async {
        if (request.method == 'POST') {
          expect(request.url.path, '/config/update');
          posts.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response(jsonEncode(_body(2, _config(updatedBy: 'app-seed'))), 200);
        }
        return http.Response(
          jsonEncode(_body(1, _config(updatedBy: 'init'), bounds: bounds)),
          200,
          headers: {'etag': '"1"'},
        );
      });
      await StrategyConfig.instance.refresh(client: client);

      expect(posts, hasLength(1));
      final post = posts.single;
      expect(post['base_revision'], 1);
      expect(post['updated_by'], 'app-seed');
      expect(post['confirm_risk_increase'], isTrue);
      final patch = post['patch'] as Map<String, dynamic>;
      final engines = patch['engines'] as Map<String, dynamic>;
      expect((engines['orb'] as Map)['enabled'], isTrue);
      expect((engines['breakout'] as Map)['enabled'], isTrue);
      expect((engines['breakout'] as Map)['dxy'], 'off');
      expect((engines['range_bounce'] as Map)['enabled'], isTrue);
      expect(((patch['filters'] as Map)['dxy'] as Map)['enabled'], isTrue);
      final limits = patch['account_limits'] as Map;
      expect(limits['max_spread_pips'], 60, reason: '.env value 99 must be clamped to the hard maximum');
      expect(limits['risk_percent_per_trade'], 1.0);
      expect((patch['trade_rules'] as Map)['one_active_trade'], isTrue);
      expect(StrategyConfig.instance.pending?.revision, 2);
    });

    test('an already-edited bridge config is never overwritten by the seed', () async {
      _liveEnv('USE_ORB=true');
      var posts = 0;
      final client = MockClient((request) async {
        if (request.method == 'POST') posts++;
        return http.Response(jsonEncode(_body(7, _config(updatedBy: 'app'))), 200);
      });
      await StrategyConfig.instance.refresh(client: client);
      expect(posts, 0);
    });

    test('the seed is attempted only once per process', () async {
      _liveEnv();
      var posts = 0;
      final client = MockClient((request) async {
        if (request.method == 'POST') {
          posts++;
          return http.Response('{"detail": "refused"}', 400);
        }
        return http.Response(jsonEncode(_body(1, _config(updatedBy: 'init'))), 200);
      });
      await StrategyConfig.instance.refresh(client: client);
      await StrategyConfig.instance.refresh(client: client);
      expect(posts, 1);
    });
  });

  group('engine thresholds', () {
    Map<String, dynamic> withParams(Map<String, Map<String, dynamic>> params) {
      final config = _config();
      for (final e in params.entries) {
        (config['engines'] as Map<String, dynamic>)[e.key] = {
          ...(config['engines'] as Map<String, dynamic>)[e.key] as Map<String, dynamic>,
          'params': e.value,
        };
      }
      return config;
    }

    test('without bridge values every threshold falls back to .env, then to the built-in default', () {
      dotenv.testLoad(
          fileInput:
              'USE_MOCK_DATA=true\nBREAKOUT_MIN_BODY_ATR=0.9\nBREAKOUT_FAILED_REVERSAL=true\nORB_STOP_LOSS_PIPS=90');
      expect(AppConfig.breakoutMinBodyToAtrRatio, 0.9);
      expect(AppConfig.breakoutFailedReversalEnabled, isTrue);
      expect(AppConfig.orbStopLossPipsOverride, 90.0);
      expect(AppConfig.zoneBounceEvaluatedZoneCount, 3);
      expect(AppConfig.htfRetestMinRiskReward, 1.5);
      expect(AppConfig.minConfluenceScoreIctReversal, 70);
      expect(AppConfig.iciMinStopLossPips, 30.0);
    });

    test('bridge values win over .env, for every engine', () {
      dotenv.testLoad(fileInput: 'USE_MOCK_DATA=true\nBREAKOUT_MIN_BODY_ATR=0.9\nORB_STOP_LOSS_PIPS=90');
      StrategyConfig.instance.setSnapshot(_snap(
          5,
          withParams({
            EngineIds.htfRetest: {'min_rr': 2.2},
            EngineIds.ict: {'min_confluence_reversal': 82},
            EngineIds.ici: {
              'min_impulse_body_ratio': 0.7,
              'min_consecutive_impulse': 3,
              'min_rejection_wick_ratio': 0.4,
              'min_sl_pips': 45.0,
            },
            EngineIds.orb: {'sl_pips_override': 120.0, 'tp_pips_override': 300.0},
            EngineIds.breakout: {
              'min_body_atr': 0.3,
              'require_retest': false,
              'retest_lookback': 12,
              'htf_mode': 'off'
            },
            EngineIds.rangeBounce: {'touch_dollars': 2.5, 'zone_count': 5, 'min_rr': 1.6},
          })));
      expect(AppConfig.htfRetestMinRiskReward, 2.2);
      expect(AppConfig.minConfluenceScoreIctReversal, 82);
      expect(AppConfig.iciMinImpulseBodyRatio, 0.7);
      expect(AppConfig.iciMinConsecutiveImpulseCandles, 3);
      expect(AppConfig.iciMinRejectionWickRatio, 0.4);
      expect(AppConfig.iciMinStopLossPips, 45.0);
      expect(AppConfig.orbStopLossPipsOverride, 120.0);
      expect(AppConfig.orbTakeProfitPipsOverride, 300.0);
      expect(AppConfig.breakoutMinBodyToAtrRatio, 0.3);
      expect(AppConfig.breakoutRequireRetest, isFalse);
      expect(AppConfig.breakoutRetestLookbackCandles, 12);
      expect(AppConfig.breakoutHtfMode, 'off');
      expect(AppConfig.zoneBounceTouchDollars, 2.5);
      expect(AppConfig.zoneBounceEvaluatedZoneCount, 5);
      expect(AppConfig.zoneBounceMinRiskReward, 1.6);
    });

    test('a threshold the bridge does not carry still comes from .env', () {
      dotenv.testLoad(fileInput: 'USE_MOCK_DATA=true\nBREAKOUT_SL_ATR=2.0');
      StrategyConfig.instance.setSnapshot(_snap(
          5,
          withParams({
            EngineIds.breakout: {'min_body_atr': 0.3}
          })));
      expect(AppConfig.breakoutMinBodyToAtrRatio, 0.3);
      expect(AppConfig.breakoutSlAtrMultiplier, 2.0);
    });

    test('the env map covers every engine and the thresholds the control screen offers', () {
      dotenv.testLoad(fileInput: 'USE_MOCK_DATA=true');
      final env = AppConfig.engineParamsFromEnv;
      expect(env.keys.toSet(), {
        EngineIds.htfRetest,
        EngineIds.ict,
        EngineIds.ici,
        EngineIds.orb,
        EngineIds.breakout,
        EngineIds.rangeBounce,
      });
      expect(env[EngineIds.breakout]!.keys, containsAll(['min_body_atr', 'failed_reversal', 'htf_mode', 'sl_atr']));
      expect(env[EngineIds.rangeBounce]!.length, 7);
    });

    group('one-time move from .env into the bridge', () {
      setUp(() => SharedPreferences.setMockInitialValues({}));

      Future<List<Map<String, dynamic>>> refreshOnce(Map<String, dynamic> bridgeConfig) async {
        final posts = <Map<String, dynamic>>[];
        final client = MockClient((request) async {
          if (request.method == 'POST') {
            posts.add(jsonDecode(request.body) as Map<String, dynamic>);
            return http.Response(jsonEncode(_body(8, bridgeConfig)), 200);
          }
          return http.Response(
            jsonEncode(_body(7, bridgeConfig, bounds: {
              'engines.breakout.params.min_body_atr': {'type': 'float', 'min': 0.2, 'max': 2.0},
              'engines.orb.params.htf_mode': {
                'type': 'enum',
                'values': ['block', 'score', 'off']
              },
            })),
            200,
          );
        });
        await StrategyConfig.instance.refresh(client: client);
        return posts;
      }

      Map<String, dynamic> bridgeAtDefaults() => withParams({
            EngineIds.breakout: {'min_body_atr': 0.6, 'failed_reversal': false, 'sl_atr': 1.2},
            EngineIds.orb: {'sl_pips_override': 0.0, 'tp_pips_override': 0.0},
          });

      test('only the values .env changes are sent, clamped to the bridge bounds', () async {
        _liveEnv('BREAKOUT_FAILED_REVERSAL=true\nBREAKOUT_MIN_BODY_ATR=5.0');
        final posts = await refreshOnce(bridgeAtDefaults());
        expect(posts, hasLength(1));
        expect(posts.single['updated_by'], 'app-seed');
        expect(posts.single['base_revision'], 7);
        final engines = (posts.single['patch'] as Map)['engines'] as Map;
        final breakout = (engines[EngineIds.breakout] as Map)['params'] as Map;
        expect(breakout['failed_reversal'], isTrue);
        expect(breakout['min_body_atr'], 2.0, reason: 'clamped to the hard bound');
        expect(breakout.containsKey('sl_atr'), isFalse, reason: 'values already equal are not re-sent');
        expect(engines.containsKey(EngineIds.orb), isFalse, reason: 'ORB values already equal are not sent');
      });

      test('it happens once: a second start does not overwrite later edits', () async {
        _liveEnv('BREAKOUT_FAILED_REVERSAL=true');
        expect(await refreshOnce(bridgeAtDefaults()), hasLength(1));
        StrategyConfig.instance.resetForTesting();
        expect(await refreshOnce(bridgeAtDefaults()), isEmpty);
      });

      test('a refused move is retried on the next start', () async {
        _liveEnv('BREAKOUT_FAILED_REVERSAL=true');
        final client = MockClient((request) async {
          if (request.method == 'POST') return http.Response('{"detail":"no"}', 500);
          return http.Response(jsonEncode(_body(7, bridgeAtDefaults())), 200);
        });
        await StrategyConfig.instance.refresh(client: client);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('aureus_engine_params_seeded_v1'), isNull);
        StrategyConfig.instance.resetForTesting();
        expect(await refreshOnce(bridgeAtDefaults()), hasLength(1));
      });
    });
  });

  group('SignalChecker integration (mock data)', () {
    setUp(() => dotenv.testLoad(fileInput: 'USE_MOCK_DATA=true'));

    test('mode.paused stops new signals but the scan still completes', () async {
      StrategyConfig.instance.setSnapshot(_snap(11, _config(paused: true)));
      final result = await SignalChecker().check();
      expect(result.setups, isEmpty);
      expect(result.status, contains('Paused by the bridge config'));
    });

    test('switched-off engines are reported and never fire', () async {
      StrategyConfig.instance.setSnapshot(
        _snap(12, _config(enabled: {for (final id in EngineIds.all) id: false})),
      );
      final result = await SignalChecker().check();
      expect(result.setups, isEmpty);
      expect(result.status, contains('Engines OFF: htf_retest, ict, ici, orb, breakout, range_bounce'));
    });
  });

  group('TradeSetup.configRevision', () {
    TradeSetup make() => TradeSetup(
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

    test('round-trips through JSON', () {
      final setup = make()..configRevision = 42;
      expect(TradeSetup.fromJson(setup.toJson()).configRevision, 42);
    });

    test('history saved before the field existed still loads', () {
      final json = make().toJson()..remove('config_revision');
      expect(TradeSetup.fromJson(json).configRevision, isNull);
    });
  });
}
