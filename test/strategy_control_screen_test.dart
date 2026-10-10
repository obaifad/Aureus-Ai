import 'dart:convert';

import 'package:aureus_ai/screens/strategy_control_screen.dart';
import 'package:aureus_ai/services/strategy_config_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _enginePriority = {
  'htf_retest': 1,
  'ict': 2,
  'orb': 3,
  'ici': 4,
  'breakout': 5,
  'range_bounce': 6,
};

const Map<String, Map<String, dynamic>> _engineParams = {
  'htf_retest': {'min_rr': 1.5},
  'ict': {'min_confluence_reversal': 70},
  'ici': {
    'min_impulse_body_ratio': 0.65,
    'min_consecutive_impulse': 2,
    'min_rejection_wick_ratio': 0.5,
    'min_sl_pips': 30.0
  },
  'orb': {'sl_pips_override': 0.0, 'tp_pips_override': 0.0},
  'breakout': {
    'min_body_atr': 0.6,
    'max_body_atr': 2.5,
    'close_location': 0.7,
    'min_range_expansion': 1.2,
    'max_entry_distance_atr': 0.8,
    'require_retest': true,
    'retest_lookback': 24,
    'retest_tolerance_dollars': 0.5,
    'failed_reversal': false,
    'sl_atr': 1.2,
    'htf_mode': 'block',
  },
  'range_bounce': {
    'touch_dollars': 1.0,
    'min_wick_ratio': 0.5,
    'break_lookback': 10,
    'sl_atr': 0.5,
    'min_boundary_r': 1.0,
    'min_rr': 1.2,
    'zone_count': 3,
  },
};

Map<String, dynamic> _paramBound(Object value) {
  if (value is bool) return {'type': 'bool', 'nullable': false};
  if (value is String) {
    return {
      'type': 'enum',
      'values': ['block', 'score', 'off'],
      'nullable': false
    };
  }
  if (value is int) return {'type': 'int', 'min': 1, 'max': 100, 'nullable': false};
  return {'type': 'float', 'min': 0.0, 'max': 500.0, 'nullable': false};
}

Map<String, dynamic> _bound(num min, num max) => {'type': 'float', 'min': min, 'max': max, 'nullable': false};

/// A tiny stand-in for the bridge's /config endpoints.
class _FakeBridge {
  int revision = 3;
  bool fingerprintMismatch = false;
  String? rejectNextUpdateWith; // 'stale' | 'rate'
  List<String> riskyPaths = const [];
  final List<Map<String, dynamic>> updates = [];
  int gets = 0;
  int acks = 0;
  int closeAllCalls = 0;
  int overrides = 0;
  Map<String, dynamic>? risk;
  List<Map<String, dynamic>> closeAllResults = const [];

  late Map<String, dynamic> config = {
    'revision': 3,
    'updated_by': 'app',
    'mode': {'paused': false, 'auto_trade': 'off'},
    'account_limits': {
      'risk_percent_per_trade': 1.0,
      'max_daily_loss_percent': 3.0,
      'max_spread_pips': 30.0,
      'max_open_positions': 1,
      'max_lot': 5.0,
      'max_slippage_points': 20,
      'entry_drift_chase_r': 0.25,
      'strict_min_lot_risk': false,
      'lot_mode': 'dynamic',
      'fixed_lot_size': 0.01,
      'min_lot': 0.01,
      'on_daily_loss': 'block',
    },
    'trade_rules': {'one_active_trade': true, 'default_rr': 1.8},
    'filters': {
      'dxy': {'enabled': true},
      'news': {'enabled': true, 'blackout_minutes': 15},
    },
    'engines': {
      for (final e in _enginePriority.entries)
        e.key: {
          'enabled': true,
          'priority': e.value,
          'dxy': e.key == 'range_bounce' ? 'exempt' : 'block',
          'max_spread_pips': null,
          'params': {...?_engineParams[e.key]},
        },
    },
  };

  Map<String, dynamic> get _bounds => {
        'account_limits.risk_percent_per_trade': _bound(0.05, 2.0),
        'account_limits.max_daily_loss_percent': _bound(0.5, 5.0),
        'account_limits.max_spread_pips': _bound(1, 60),
        'account_limits.max_open_positions': {'type': 'int', 'min': 1, 'max': 3},
        'account_limits.max_lot': _bound(0.01, 10),
        'account_limits.max_slippage_points': {'type': 'int', 'min': 0, 'max': 100},
        'account_limits.entry_drift_chase_r': _bound(0.0, 0.5),
        'filters.news.blackout_minutes': {'type': 'int', 'min': 0, 'max': 120},
        'account_limits.strict_min_lot_risk': {'type': 'bool', 'nullable': false},
        'account_limits.lot_mode': {
          'type': 'enum',
          'values': ['dynamic', 'fixed'],
        },
        'account_limits.fixed_lot_size': _bound(0.01, 10.0),
        'trade_rules.default_rr': _bound(1.0, 4.0),
        'account_limits.on_daily_loss': {
          'type': 'enum',
          'values': ['block', 'close_all'],
        },
        for (final id in _enginePriority.keys) ...{
          'engines.$id.max_spread_pips': {'type': 'float', 'min': 1, 'max': 60, 'nullable': true},
          'engines.$id.rr': {'type': 'float', 'min': 1.0, 'max': 4.0, 'nullable': true},
          'engines.$id.dxy': {
            'type': 'enum',
            'values': ['block', 'score', 'off', 'exempt'],
          },
          for (final p in (_engineParams[id] ?? const <String, dynamic>{}).entries)
            'engines.$id.params.${p.key}': _paramBound(p.value),
        },
      };

  Map<String, dynamic> body({List<String> warnings = const []}) => {
        'config': {...config, 'revision': revision},
        'revision': revision,
        'bounds': _bounds,
        'meta': {'fingerprint_mismatch': fingerprintMismatch, 'enforced_by_bridge': <String>[]},
        'warnings': warnings,
      };

  void _merge(Map<String, dynamic> base, Map<String, dynamic> patch) {
    patch.forEach((k, v) {
      if (v is Map<String, dynamic> && base[k] is Map<String, dynamic>) {
        _merge(base[k] as Map<String, dynamic>, v);
      } else {
        base[k] = v;
      }
    });
  }

  http.Response handle(http.Request request) {
    if (request.method == 'GET' && request.url.path == '/config') {
      gets++;
      return http.Response(jsonEncode(body()), 200, headers: {'etag': '"$revision"'});
    }
    if (request.method == 'GET' && request.url.path == '/risk/status') {
      return risk == null ? http.Response('not found', 404) : http.Response(jsonEncode(risk), 200);
    }
    if (request.method == 'POST' && request.url.path == '/risk/override') {
      overrides++;
      risk = {...risk!, 'locked': false, 'overrides_today': 1, 'locked_loss_percent': null, 'loss_percent': 0.0};
      return http.Response(jsonEncode(risk), 200);
    }
    if (request.method == 'POST' && request.url.path == '/order/close_all') {
      closeAllCalls++;
      return http.Response(
        jsonEncode({'success': closeAllResults.every((c) => c['success'] == true), 'closed': closeAllResults}),
        200,
      );
    }
    if (request.method == 'POST' && request.url.path == '/config/ack_account') {
      acks++;
      fingerprintMismatch = false;
      return http.Response(jsonEncode(body()), 200);
    }
    if (request.method == 'POST' && request.url.path == '/config/update') {
      final req = jsonDecode(request.body) as Map<String, dynamic>;
      updates.add(req);
      if (rejectNextUpdateWith == 'stale') {
        rejectNextUpdateWith = null;
        revision++; // somebody else saved first
        return http.Response(
          jsonEncode({
            'detail': {
              'code': 'stale_revision',
              'message': 'Config changed since you loaded it.',
              'current_revision': revision
            }
          }),
          409,
        );
      }
      if (rejectNextUpdateWith == 'rate') {
        rejectNextUpdateWith = null;
        return http.Response(
          jsonEncode({
            'detail': {'code': 'risk_increase_rate_limited', 'message': 'At most 3 risk-increasing changes per hour.'}
          }),
          429,
        );
      }
      if (riskyPaths.isNotEmpty && req['confirm_risk_increase'] != true) {
        return http.Response(
          jsonEncode({
            'detail': {
              'code': 'confirmation_required',
              'message': 'These changes increase account risk.',
              'risk_increasing': riskyPaths,
            }
          }),
          428,
        );
      }
      _merge(config, req['patch'] as Map<String, dynamic>);
      revision++;
      return http.Response(jsonEncode(body()), 200);
    }
    return http.Response('not found', 404);
  }
}

void main() {
  late _FakeBridge bridge;
  late MockClient client;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    StrategyConfig.instance.resetForTesting();
    dotenv.testLoad(
      fileInput: 'USE_MOCK_DATA=false\nDISABLE_MT5_BRIDGE=false\nBRIDGE_BASE_URL=http://bridge.test',
    );
    bridge = _FakeBridge();
    client = MockClient((request) async => bridge.handle(request));
  });
  tearDown(() => StrategyConfig.instance.resetForTesting());

  Future<void> open(WidgetTester tester) async {
    // Tall enough that the whole page is on screen (each setting added to the page makes it longer).
    tester.view.physicalSize = const Size(800, 3800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: StrategyControlScreen(client: client)));
    await tester.pumpAndSettle();
  }

  testWidgets('loads the live config: revision, all six engines, pause off', (tester) async {
    await open(tester);
    expect(find.text('rev 3'), findsOneWidget);
    expect(find.text('Pause all new signals'), findsOneWidget);
    for (final id in _enginePriority.keys) {
      expect(find.byKey(Key('engine-$id')), findsOneWidget, reason: id);
    }
    expect(find.byKey(const Key('save-button')), findsNothing);
  });

  testWidgets('editing stages a change; Save sends only what changed', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('engine-orb-enabled')));
    await tester.pump();
    expect(find.text('1 unsaved change'), findsOneWidget);
    expect(bridge.updates, isEmpty, reason: 'nothing is sent before Save');

    await tester.tap(find.byKey(const Key('save-button')));
    await tester.pumpAndSettle();

    expect(bridge.updates, hasLength(1));
    final sent = bridge.updates.single;
    expect(sent['base_revision'], 3);
    expect(sent['confirm_risk_increase'], isFalse);
    expect(sent['patch'], {
      'engines': {
        'orb': {'enabled': false},
      },
    });
    expect(find.byKey(const Key('save-button')), findsNothing);
    expect(find.text('rev 4'), findsOneWidget);
    expect(find.textContaining('Saved'), findsOneWidget);
  });

  testWidgets('Discard drops staged edits without calling the bridge', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('engine-ict-enabled')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('discard-button')));
    await tester.pump();
    expect(find.byKey(const Key('save-button')), findsNothing);
    expect(bridge.updates, isEmpty);
  });

  testWidgets('toggling back to the server value un-stages the edit', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('engine-ict-enabled')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('engine-ict-enabled')));
    await tester.pump();
    expect(find.byKey(const Key('save-button')), findsNothing);
  });

  testWidgets('a risk-increasing change asks for confirmation, then resends with confirm', (tester) async {
    bridge.riskyPaths = ['filters.dxy.enabled'];
    await open(tester);
    await tester.tap(find.byKey(const Key('filters.dxy.enabled')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('save-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('risk-dialog')), findsOneWidget);
    expect(find.textContaining('DXY correlation filter: on → off'), findsOneWidget);

    await tester.tap(find.byKey(const Key('risk-confirm')));
    await tester.pumpAndSettle();

    expect(bridge.updates, hasLength(2));
    expect(bridge.updates[0]['confirm_risk_increase'], isFalse);
    expect(bridge.updates[1]['confirm_risk_increase'], isTrue);
    expect(find.byKey(const Key('save-button')), findsNothing);
  });

  testWidgets('cancelling the risk dialog sends nothing more and keeps the edit staged', (tester) async {
    bridge.riskyPaths = ['filters.dxy.enabled'];
    await open(tester);
    await tester.tap(find.byKey(const Key('filters.dxy.enabled')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('save-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(bridge.updates, hasLength(1));
    expect(find.byKey(const Key('save-button')), findsOneWidget);
  });

  testWidgets('Pause applies immediately, with no Save step', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('pause-switch')));
    await tester.pumpAndSettle();

    expect(bridge.updates, hasLength(1));
    expect(bridge.updates.single['patch'], {
      'mode': {'paused': true},
    });
    expect(find.text('Trading is PAUSED'), findsOneWidget);
    expect(find.byKey(const Key('save-button')), findsNothing);
  });

  testWidgets('resuming goes through the confirmation flow', (tester) async {
    bridge.config['mode'] = {'paused': true, 'auto_trade': 'off'};
    bridge.riskyPaths = ['mode.paused'];
    await open(tester);
    expect(find.text('Trading is PAUSED'), findsOneWidget);

    await tester.tap(find.byKey(const Key('pause-switch')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('risk-dialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('risk-confirm')));
    await tester.pumpAndSettle();

    expect(bridge.updates.last['confirm_risk_increase'], isTrue);
    expect(find.text('Pause all new signals'), findsOneWidget);
  });

  testWidgets('a stale revision reloads the config instead of overwriting', (tester) async {
    await open(tester);
    bridge.rejectNextUpdateWith = 'stale';
    await tester.tap(find.byKey(const Key('engine-ict-enabled')));
    await tester.pump();
    final getsBefore = bridge.gets;
    await tester.tap(find.byKey(const Key('save-button')));
    await tester.pumpAndSettle();

    expect(bridge.gets, getsBefore + 1, reason: 'reloaded after the 409');
    expect(find.text('rev 4'), findsOneWidget);
    expect(find.textContaining('changed elsewhere'), findsOneWidget);
    expect(find.byKey(const Key('save-button')), findsOneWidget, reason: 'the edit is kept for review');
  });

  testWidgets('a rate-limited risk increase shows the bridge message', (tester) async {
    await open(tester);
    bridge.rejectNextUpdateWith = 'rate';
    await tester.tap(find.byKey(const Key('engine-ict-enabled')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('save-button')));
    await tester.pumpAndSettle();
    expect(find.text('Too many risk increases'), findsOneWidget);
    expect(find.textContaining('3 risk-increasing changes per hour'), findsOneWidget);
  });

  testWidgets('an engine can get its own spread cap, sent as a number', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('engine-orb')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('engine-orb-own-spread')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('save-button')));
    await tester.pumpAndSettle();

    final patch = bridge.updates.single['patch'] as Map<String, dynamic>;
    expect(patch, {
      'engines': {
        'orb': {'max_spread_pips': 30.0},
      },
    });
  });

  testWidgets('a mismatched MT5 account is flagged and can be acknowledged', (tester) async {
    bridge.fingerprintMismatch = true;
    await open(tester);
    expect(find.textContaining('connected MT5 account is different'), findsOneWidget);
    await tester.tap(find.byKey(const Key('ack-account')));
    await tester.pumpAndSettle();
    expect(bridge.acks, 1);
    expect(find.textContaining('connected MT5 account is different'), findsNothing);
  });

  testWidgets('Emergency stop asks first, then pauses and closes everything', (tester) async {
    bridge.closeAllResults = [
      {'ticket': 1, 'success': true, 'price': 2400.0},
    ];
    await open(tester);
    await tester.tap(find.byKey(const Key('emergency-stop')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('emergency-dialog')), findsOneWidget);
    expect(bridge.closeAllCalls, 0, reason: 'nothing happens before confirming');

    await tester.tap(find.byKey(const Key('emergency-confirm')));
    await tester.pumpAndSettle();

    expect(bridge.closeAllCalls, 1);
    expect(bridge.updates.single['patch'], {
      'mode': {'paused': true},
    });
    expect(find.byKey(const Key('emergency-result')), findsOneWidget);
    expect(find.text('Stopped'), findsOneWidget);
    expect(find.textContaining('1 position(s) closed'), findsOneWidget);
  });

  testWidgets('Emergency stop reports positions that could not be closed', (tester) async {
    bridge.closeAllResults = [
      {'ticket': 9, 'success': false, 'error': 'Market closed'},
    ];
    await open(tester);
    await tester.tap(find.byKey(const Key('emergency-stop')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('emergency-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('Needs attention'), findsOneWidget);
    expect(find.textContaining('STILL OPEN'), findsOneWidget);
    expect(find.textContaining('#9: Market closed'), findsOneWidget);
  });

  testWidgets('cancelling the emergency dialog does nothing', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('emergency-stop')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(bridge.closeAllCalls, 0);
    expect(bridge.updates, isEmpty);
  });

  Map<String, dynamic> riskPayload(
          {bool locked = false, double loss = 1.0, int overrides = 0, bool available = true}) =>
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
        'on_breach': 'block',
      };

  testWidgets('the daily loss card shows how much of the limit is used', (tester) async {
    bridge.risk = riskPayload(loss: 1.0);
    await open(tester);
    expect(find.byKey(const Key('daily-loss-card')), findsOneWidget);
    expect(find.textContaining('−1.00% of 3.00% limit'), findsOneWidget);
    expect(find.textContaining('day started at 10000'), findsOneWidget);
    expect(find.byKey(const Key('daily-loss-override')), findsNothing, reason: 'nothing to unlock');
  });

  testWidgets('a profitable day is shown as a gain', (tester) async {
    bridge.risk = riskPayload(loss: -0.5);
    await open(tester);
    expect(find.textContaining('+0.50% of 3.00% limit'), findsOneWidget);
  });

  testWidgets('a locked account is flagged and can be unlocked after confirming', (tester) async {
    bridge.risk = riskPayload(locked: true, loss: 3.2);
    await open(tester);
    expect(find.textContaining('Trading is LOCKED until 00:00 UTC'), findsOneWidget);
    expect(find.textContaining('lost 3.20%'), findsOneWidget);

    await tester.tap(find.byKey(const Key('daily-loss-override')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('override-dialog')), findsOneWidget);
    expect(bridge.overrides, 0, reason: 'nothing happens before confirming');

    await tester.tap(find.byKey(const Key('override-confirm')));
    await tester.pumpAndSettle();
    expect(bridge.overrides, 1);
    expect(find.textContaining('Trading is LOCKED'), findsNothing);
    expect(find.textContaining('Unlocked'), findsOneWidget);
  });

  testWidgets('keeping the lock does nothing', (tester) async {
    bridge.risk = riskPayload(locked: true, loss: 3.2);
    await open(tester);
    await tester.tap(find.byKey(const Key('daily-loss-override')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep locked'));
    await tester.pumpAndSettle();
    expect(bridge.overrides, 0);
    expect(find.textContaining('Trading is LOCKED'), findsOneWidget);
  });

  testWidgets('once the daily override is used the button is disabled', (tester) async {
    bridge.risk = riskPayload(locked: true, loss: 3.5, overrides: 1);
    await open(tester);
    final button = tester.widget<OutlinedButton>(find.byKey(const Key('daily-loss-override')));
    expect(button.onPressed, isNull);
    expect(find.text('Override already used today'), findsOneWidget);
  });

  testWidgets('no card when the bridge cannot read the account', (tester) async {
    bridge.risk = riskPayload(available: false);
    await open(tester);
    expect(find.byKey(const Key('daily-loss-card')), findsNothing);
  });

  testWidgets('the daily-limit action can be switched to closing everything', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('account_limits.on_daily_loss')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close all positions').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-button')));
    await tester.pumpAndSettle();
    expect(bridge.updates.single['patch'], {
      'account_limits': {'on_daily_loss': 'close_all'},
    });
  });

  testWidgets('moving an engine down swaps priorities with its neighbour, as one change', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('engine-htf_retest')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('engine-htf_retest-down')));
    await tester.pump();
    expect(find.text('2 unsaved changes'), findsOneWidget);
    await tester.tap(find.byKey(const Key('save-button')));
    await tester.pumpAndSettle();
    expect(bridge.updates.single['patch'], {
      'engines': {
        'htf_retest': {'priority': 2},
        'ict': {'priority': 1},
      },
    });
  });

  testWidgets('the first engine cannot move up and the last cannot move down', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('engine-htf_retest')));
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(find.byKey(const Key('engine-htf_retest-up'))).onPressed, isNull);
    await tester.tap(find.byKey(const Key('engine-range_bounce')));
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(find.byKey(const Key('engine-range_bounce-down'))).onPressed, isNull);
  });

  testWidgets('an engine can get its own R:R target, starting from the default', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('engine-orb')));
    await tester.pumpAndSettle();
    expect(find.textContaining('using default 1.8'), findsOneWidget);
    await tester.tap(find.byKey(const Key('engine-orb-own-rr')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('save-button')));
    await tester.pumpAndSettle();
    expect(bridge.updates.single['patch'], {
      'engines': {
        'orb': {'rr': 1.8},
      },
    });
  });

  testWidgets('the default reward : risk is adjustable for every engine', (tester) async {
    await open(tester);
    expect(find.byKey(const Key('trade_rules.default_rr')), findsOneWidget);
    expect(find.textContaining('1.8 R'), findsOneWidget);
  });

  group('late-approval tolerance', () {
    testWidgets('is shown with the value the bridge has and explains what it does', (tester) async {
      await open(tester);
      final slider = find.byKey(const Key('account_limits.entry_drift_chase_r'));
      await tester.scrollUntilVisible(slider, 200, scrollable: find.byType(Scrollable).first);
      expect(find.text('Late-approval tolerance'), findsOneWidget);
      expect(find.text('0.25 R'), findsOneWidget);
      expect(find.textContaining('0 = only the flat'), findsOneWidget);
      expect(tester.widget<Slider>(slider).max, 0.5);
    });

    testWidgets('moves in steps of 0.05 and is saved as a plain number', (tester) async {
      await open(tester);
      final slider = find.byKey(const Key('account_limits.entry_drift_chase_r'));
      await tester.scrollUntilVisible(slider, 200, scrollable: find.byType(Scrollable).first);
      await tester.drag(slider, const Offset(-400, 0)); // all the way to 0
      await tester.pump();
      expect(find.text('1 unsaved change'), findsOneWidget);
      await tester.tap(find.byKey(const Key('save-button')));
      await tester.pumpAndSettle();
      expect(bridge.updates.single['patch'], {
        'account_limits': {'entry_drift_chase_r': 0.0},
      });
    });

    testWidgets('is not offered by a bridge that does not know it', (tester) async {
      (bridge.config['account_limits'] as Map).remove('entry_drift_chase_r');
      await open(tester);
      expect(find.byKey(const Key('account_limits.entry_drift_chase_r')), findsNothing);
      expect(find.text('Late-approval tolerance'), findsNothing);
    });
  });

  testWidgets('the strict minimum-lot switch is saved as a plain on/off', (tester) async {
    await open(tester);
    final tile = find.byKey(const Key('account_limits.strict_min_lot_risk'));
    await tester.scrollUntilVisible(tile, 200, scrollable: find.byType(Scrollable).first);
    expect(find.textContaining('Refuse a trade whose smallest lot risks too much'), findsOneWidget);
    await tester.tap(tile);
    await tester.pump();
    await tester.tap(find.byKey(const Key('save-button')));
    await tester.pumpAndSettle();
    expect(bridge.updates.single['patch'], {
      'account_limits': {'strict_min_lot_risk': true},
    });
  });

  group('lot mode', () {
    final field = find.byType(TextFormField);
    Finder segment(String label) => find.descendant(of: find.byKey(const Key('lot-mode')), matching: find.text(label));
    FilledButton saveButton(WidgetTester tester) => tester.widget<FilledButton>(find.byKey(const Key('save-button')));

    Future<void> chooseFixed(WidgetTester tester) async {
      await open(tester);
      await tester.tap(segment('Fixed lot'));
      await tester.pump();
    }

    Future<void> type(WidgetTester tester, String text) async {
      await tester.enterText(field, text);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400)); // the old error fades out
    }

    testWidgets('the selector shows the bridge\'s mode and no lot box while it is dynamic', (tester) async {
      await open(tester);
      expect(find.byKey(const Key('lot-mode')), findsOneWidget);
      expect(tester.widget<SegmentedButton<String>>(find.byKey(const Key('lot-mode'))).selected, {'dynamic'});
      expect(field, findsNothing);
      expect(find.textContaining('sized from "Risk per trade"'), findsOneWidget);
    });

    testWidgets('choosing Fixed lot shows the box with the stored size and explains how it works', (tester) async {
      await chooseFixed(tester);
      expect(field, findsOneWidget);
      expect(tester.widget<TextFormField>(field).initialValue, '0.01');
      expect(find.textContaining('Between 0.01 and 5 lot'), findsOneWidget, reason: 'the bridge max lot (5) is the ceiling');
      expect(find.textContaining('daily loss limit still comes first'), findsOneWidget);
      expect(find.text('1 unsaved change'), findsOneWidget);
    });

    testWidgets('a valid lot is saved together with the mode, as plain numbers', (tester) async {
      await chooseFixed(tester);
      await type(tester, '0.05');
      expect(find.text('2 unsaved changes'), findsOneWidget);
      await tester.tap(find.byKey(const Key('save-button')));
      await tester.pumpAndSettle();
      expect(bridge.updates.single['patch'], {
        'account_limits': {'lot_mode': 'fixed', 'fixed_lot_size': 0.05},
      });
      expect(find.text('rev 4'), findsOneWidget);
    });

    testWidgets('a comma is accepted as the decimal mark', (tester) async {
      await chooseFixed(tester);
      await type(tester, '0,25');
      await tester.tap(find.byKey(const Key('save-button')));
      await tester.pumpAndSettle();
      expect((bridge.updates.single['patch'] as Map)['account_limits']['fixed_lot_size'], 0.25);
    });

    testWidgets('the highest allowed lot is accepted', (tester) async {
      await chooseFixed(tester);
      await type(tester, '5');
      expect(find.text('The maximum is 5 lot (your max lot size)'), findsNothing);
      expect(saveButton(tester).onPressed, isNotNull);
    });

    for (final bad in {
      '': 'Enter a number',
      'abc': 'Enter a number',
      '0.005': 'The minimum is 0.01 lot',
      '0': 'The minimum is 0.01 lot',
      '-1': 'The minimum is 0.01 lot',
      '5.01': 'The maximum is 5 lot',
      '6': 'The maximum is 5 lot',
      '0.015': 'Use steps of 0.01',
      '1.234': 'Use steps of 0.01',
    }.entries) {
      testWidgets('"${bad.key}" is refused with a reason and Save stays off', (tester) async {
        await chooseFixed(tester);
        await type(tester, bad.key);
        expect(find.textContaining(bad.value), findsOneWidget);
        expect(saveButton(tester).onPressed, isNull);
        expect(bridge.updates, isEmpty);
      });
    }

    testWidgets('fixing a bad entry turns Save back on', (tester) async {
      await chooseFixed(tester);
      await type(tester, '9');
      expect(saveButton(tester).onPressed, isNull);
      await type(tester, '0.5');
      expect(find.textContaining('The maximum is'), findsNothing);
      expect(saveButton(tester).onPressed, isNotNull);
    });

    testWidgets('the ceiling follows the max lot size the bridge has', (tester) async {
      bridge.config['account_limits']['max_lot'] = 1.0;
      await chooseFixed(tester);
      expect(find.textContaining('Between 0.01 and 1 lot'), findsOneWidget);
      await type(tester, '2');
      expect(find.textContaining('The maximum is 1 lot'), findsOneWidget);
    });

    testWidgets('a stored lot that no longer fits the limits is flagged and Save stays off until it is fixed', (tester) async {
      bridge.config['account_limits']['min_lot'] = 0.1; // the stored fixed lot is 0.01
      await chooseFixed(tester);
      expect(find.textContaining('The minimum is 0.1 lot'), findsOneWidget);
      expect(saveButton(tester).onPressed, isNull);
      await type(tester, '0.1');
      expect(find.textContaining('The minimum is'), findsNothing);
      expect(saveButton(tester).onPressed, isNotNull);
    });

    testWidgets('the floor follows the min lot size the bridge has', (tester) async {
      bridge.config['account_limits']['min_lot'] = 0.1;
      bridge.config['account_limits']['fixed_lot_size'] = 0.2;
      await chooseFixed(tester);
      expect(find.textContaining('Between 0.1 and 5 lot'), findsOneWidget);
      await type(tester, '0.05');
      expect(find.textContaining('The minimum is 0.1 lot'), findsOneWidget);
    });

    testWidgets('Discard puts the mode and the box back to what the bridge has', (tester) async {
      await chooseFixed(tester);
      await type(tester, '9');
      await tester.tap(find.byKey(const Key('discard-button')));
      await tester.pumpAndSettle();
      expect(field, findsNothing);
      expect(tester.widget<SegmentedButton<String>>(find.byKey(const Key('lot-mode'))).selected, {'dynamic'});
      expect(find.byKey(const Key('save-button')), findsNothing);
      await tester.tap(segment('Fixed lot'));
      await tester.pump();
      expect(tester.widget<TextFormField>(field).initialValue, '0.01', reason: 'the bad text is gone');
      expect(find.textContaining('The maximum is'), findsNothing);
    });

    testWidgets('going back to dynamic drops the fixed-lot edit and any error', (tester) async {
      await chooseFixed(tester);
      await type(tester, '9');
      await tester.tap(segment('Dynamic risk %'));
      await tester.pump();
      expect(field, findsNothing);
      expect(find.byKey(const Key('save-button')), findsNothing, reason: 'nothing differs from the bridge any more');
    });

    testWidgets('a lot already stored on the bridge is shown, and editing it saves only the size', (tester) async {
      bridge.config['account_limits']['lot_mode'] = 'fixed';
      bridge.config['account_limits']['fixed_lot_size'] = 0.2;
      await open(tester);
      expect(tester.widget<SegmentedButton<String>>(find.byKey(const Key('lot-mode'))).selected, {'fixed'});
      expect(tester.widget<TextFormField>(field).initialValue, '0.2');
      await type(tester, '0.15');
      await tester.tap(find.byKey(const Key('save-button')));
      await tester.pumpAndSettle();
      expect(bridge.updates.single['patch'], {
        'account_limits': {'fixed_lot_size': 0.15},
      });
    });

    testWidgets('switching to a fixed lot goes through the risk confirmation, naming the setting', (tester) async {
      bridge.riskyPaths = ['account_limits.lot_mode', 'account_limits.fixed_lot_size'];
      await chooseFixed(tester);
      await type(tester, '0.05');
      await tester.tap(find.byKey(const Key('save-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('risk-dialog')), findsOneWidget);
      expect(find.textContaining('Lot mode'), findsWidgets);
      expect(find.textContaining('Fixed lot size'), findsWidgets);
      await tester.tap(find.byKey(const Key('risk-confirm')));
      await tester.pumpAndSettle();
      expect(bridge.updates.last['confirm_risk_increase'], isTrue);
      expect(bridge.updates.last['patch'], {
        'account_limits': {'lot_mode': 'fixed', 'fixed_lot_size': 0.05},
      });
    });

    testWidgets('a bridge that does not know the setting shows no lot selector', (tester) async {
      (bridge.config['account_limits'] as Map).remove('lot_mode');
      await open(tester);
      expect(find.byKey(const Key('lot-mode')), findsNothing);
      expect(find.byKey(const Key('account_limits.risk_percent_per_trade')), findsOneWidget);
    });

    testWidgets('the bridge refusing the lot is reported and the edit stays staged', (tester) async {
      bridge.rejectNextUpdateWith = 'rate';
      await chooseFixed(tester);
      await type(tester, '0.05');
      await tester.tap(find.byKey(const Key('save-button')));
      await tester.pumpAndSettle();
      expect(find.textContaining('At most 3 risk-increasing changes per hour'), findsOneWidget);
      expect(find.byKey(const Key('save-button')), findsOneWidget);
    });
  });

  testWidgets('without a live bridge the screen explains why and offers Retry', (tester) async {
    dotenv.testLoad(fileInput: 'USE_MOCK_DATA=true');
    await open(tester);
    expect(find.text('Bridge config unavailable'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(bridge.gets, 0);
  });

  group('engine thresholds', () {
    Future<void> openEngine(WidgetTester tester, String id) async {
      await open(tester);
      await tester.tap(find.byKey(Key('engine-$id')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('engine-$id-params')));
      await tester.pumpAndSettle();
    }

    testWidgets('every engine with thresholds has an Entry thresholds section', (tester) async {
      await open(tester);
      for (final id in _engineParams.keys) {
        await tester.scrollUntilVisible(find.byKey(Key('engine-$id')), 200, scrollable: find.byType(Scrollable).first);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('engine-$id')));
        await tester.pumpAndSettle();
        expect(find.byKey(Key('engine-$id-params')), findsOneWidget, reason: id);
        await tester.tap(find.byKey(Key('engine-$id'))); // collapse again
        await tester.pumpAndSettle();
      }
      expect(find.textContaining('not editable here yet'), findsNothing);
    });

    testWidgets('the current values are shown from the bridge', (tester) async {
      await openEngine(tester, 'breakout');
      expect(find.text('Min candle body (× ATR)'), findsOneWidget);
      expect(find.byKey(const Key('engines.breakout.params.min_body_atr')), findsOneWidget);
      expect(tester.widget<Slider>(find.byKey(const Key('engines.breakout.params.min_body_atr'))).value, 0.6);
      expect(tester.widget<SwitchListTile>(find.byKey(const Key('param-breakout-require_retest'))).value, isTrue);
      expect(tester.widget<SwitchListTile>(find.byKey(const Key('param-breakout-failed_reversal'))).value, isFalse);
    });

    testWidgets('a switch threshold is saved as a nested params patch', (tester) async {
      await openEngine(tester, 'breakout');
      await tester.tap(find.byKey(const Key('param-breakout-failed_reversal')));
      await tester.pump();
      expect(find.text('1 unsaved change'), findsOneWidget);
      await tester.tap(find.byKey(const Key('save-button')));
      await tester.pumpAndSettle();
      expect(bridge.updates.single['patch'], {
        'engines': {
          'breakout': {
            'params': {'failed_reversal': true},
          },
        },
      });
    });

    testWidgets('a slider threshold moves and is saved within the bridge bounds', (tester) async {
      await openEngine(tester, 'range_bounce');
      final finder = find.byKey(const Key('engines.range_bounce.params.zone_count'));
      await tester.ensureVisible(finder);
      await tester.drag(finder, const Offset(60, 0));
      await tester.pump();
      expect(find.text('1 unsaved change'), findsOneWidget);
      await tester.tap(find.byKey(const Key('save-button')));
      await tester.pumpAndSettle();
      final sent = (bridge.updates.single['patch'] as Map)['engines']['range_bounce']['params'] as Map;
      expect(sent.keys, ['zone_count']);
      expect(sent['zone_count'], isA<int>());
      expect(sent['zone_count'], inInclusiveRange(1, 100));
      expect(sent['zone_count'], isNot(3));
    });

    testWidgets('a mode threshold is a dropdown of the values the bridge allows', (tester) async {
      await openEngine(tester, 'breakout');
      await tester.ensureVisible(find.byKey(const Key('engines.breakout.params.htf_mode')));
      await tester.tap(find.byKey(const Key('engines.breakout.params.htf_mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('score only').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-button')));
      await tester.pumpAndSettle();
      expect(bridge.updates.single['patch'], {
        'engines': {
          'breakout': {
            'params': {'htf_mode': 'score'},
          },
        },
      });
    });

    testWidgets('a threshold change that loosens the engine goes through the risk confirmation', (tester) async {
      bridge.riskyPaths = ['engines.breakout.params.require_retest'];
      await openEngine(tester, 'breakout');
      await tester.tap(find.byKey(const Key('param-breakout-require_retest')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('save-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('risk-dialog')), findsOneWidget);
      expect(find.textContaining('Breakout / Momentum · Wait for a retest'), findsOneWidget);
      await tester.tap(find.byKey(const Key('risk-confirm')));
      await tester.pumpAndSettle();
      expect(bridge.updates.last['confirm_risk_increase'], isTrue);
    });
  });
}
