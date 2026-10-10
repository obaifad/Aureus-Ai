import 'dart:convert';

import 'package:aureus_ai/models/pivot.dart';
import 'package:aureus_ai/models/trade_setup.dart';
import 'package:aureus_ai/screens/signal_detail_screen.dart';
import 'package:aureus_ai/screens/strategy_control_screen.dart';
import 'package:aureus_ai/services/strategy_config_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _modes = {
  'type': 'enum',
  'values': ['block', 'shadow', 'off'],
  'nullable': false
};

Map<String, dynamic> _float(num min, num max) => {'type': 'float', 'min': min, 'max': max, 'nullable': false};
Map<String, dynamic> _int(num min, num max) => {'type': 'int', 'min': min, 'max': max, 'nullable': false};

/// The slice of the bridge's /config the control screen needs, with the three market-safety layers in it
/// (or without them, to look like a bridge from before they existed).
class _Bridge {
  _Bridge({this.withLayers = true});
  final bool withLayers;
  int revision = 3;
  final List<Map<String, dynamic>> updates = [];

  late final Map<String, dynamic> config = {
    'revision': 3,
    'updated_by': 'app',
    'mode': {'paused': false, 'auto_trade': 'auto'},
    'account_limits': {
      'risk_percent_per_trade': 2.0,
      'max_daily_loss_percent': 5.0,
      'max_spread_pips': 30.0,
      'max_open_positions': 1,
      'max_lot': 1.0,
      'max_slippage_points': 20,
      'entry_drift_chase_r': 0.25,
      'strict_min_lot_risk': false,
      'lot_mode': 'fixed',
      'fixed_lot_size': 0.1,
      'min_lot': 0.01,
      'on_daily_loss': 'block',
    },
    'trade_rules': {'one_active_trade': true, 'default_rr': 1.8},
    'filters': {
      'dxy': {'enabled': true},
      'news': {'enabled': true, 'blackout_minutes': 15},
      if (withLayers) ...{
        'impulse': {'mode': 'shadow', 'consecutive': 3, 'shock_atr': 3.0, 'min_hours': 2.0, 'max_hours': 4.0},
        'chaos': {'mode': 'shadow', 'range_mult': 3.0, 'spread_mult': 3.0, 'pause_minutes': 15},
      },
    },
    'engines': {
      for (final (i, id) in ['htf_retest', 'ict', 'ici', 'range_bounce', 'orb', 'breakout'].indexed)
        id: {
          'enabled': true,
          'priority': i + 1,
          'dxy': 'block',
          'max_spread_pips': null,
          'params': {
            if (id == 'ict') ...{
              'min_confluence_reversal': 70,
              if (withLayers) ...{
                'sweep_mode': 'shadow',
                'sweep_range_lookback': 48,
                'sweep_min_range_atr': 2.0,
                'sweep_boundary_atr': 0.5,
                'sweep_max_efficiency': 0.35,
              },
            },
          },
        },
    },
  };

  Map<String, dynamic> get bounds => {
        'account_limits.risk_percent_per_trade': _float(0.05, 2.0),
        'account_limits.max_daily_loss_percent': _float(0.5, 5.0),
        'account_limits.max_spread_pips': _float(1, 60),
        'account_limits.max_open_positions': _int(1, 3),
        'account_limits.max_lot': _float(0.01, 10),
        'account_limits.max_slippage_points': _int(0, 100),
        'account_limits.entry_drift_chase_r': _float(0, 0.5),
        'account_limits.fixed_lot_size': _float(0.01, 10),
        'account_limits.lot_mode': {
          'type': 'enum',
          'values': ['dynamic', 'fixed']
        },
        'account_limits.on_daily_loss': {
          'type': 'enum',
          'values': ['block', 'close_all']
        },
        'trade_rules.default_rr': _float(1, 4),
        'filters.news.blackout_minutes': _int(0, 120),
        if (withLayers) ...{
          'filters.impulse.mode': _modes,
          'filters.impulse.consecutive': _int(2, 6),
          'filters.impulse.shock_atr': _float(1.5, 8),
          'filters.impulse.min_hours': _float(0.5, 6),
          'filters.impulse.max_hours': _float(0.5, 8),
          'filters.chaos.mode': _modes,
          'filters.chaos.range_mult': _float(1.5, 10),
          'filters.chaos.spread_mult': _float(1.5, 10),
          'filters.chaos.pause_minutes': _int(5, 120),
          'engines.ict.params.sweep_mode': _modes,
          'engines.ict.params.sweep_range_lookback': _int(16, 192),
          'engines.ict.params.sweep_min_range_atr': _float(0.5, 8),
          'engines.ict.params.sweep_boundary_atr': _float(0.1, 2),
          'engines.ict.params.sweep_max_efficiency': _float(0.1, 0.8),
        },
        'engines.ict.params.min_confluence_reversal': _int(50, 95),
        for (final id in ['htf_retest', 'ict', 'ici', 'range_bounce', 'orb', 'breakout']) ...{
          'engines.$id.dxy': {
            'type': 'enum',
            'values': ['block', 'score', 'off', 'exempt']
          },
          'engines.$id.rr': {'type': 'float', 'min': 1.0, 'max': 4.0, 'nullable': true},
          'engines.$id.max_spread_pips': {'type': 'float', 'min': 1, 'max': 60, 'nullable': true},
        },
      };

  Map<String, dynamic> body() => {
        'config': {...config, 'revision': revision},
        'revision': revision,
        'bounds': bounds,
        'meta': {'fingerprint_mismatch': false, 'enforced_by_bridge': <String>[]},
      };

  void merge(Map<String, dynamic> base, Map<String, dynamic> patch) {
    patch.forEach((k, v) {
      if (v is Map<String, dynamic> && base[k] is Map<String, dynamic>) {
        merge(base[k] as Map<String, dynamic>, v);
      } else {
        base[k] = v;
      }
    });
  }

  http.Response handle(http.Request request) {
    if (request.method == 'GET' && request.url.path == '/config') {
      return http.Response(jsonEncode(body()), 200, headers: {'etag': '"$revision"'});
    }
    if (request.method == 'POST' && request.url.path == '/config/update') {
      final req = jsonDecode(request.body) as Map<String, dynamic>;
      updates.add(req);
      merge(config, req['patch'] as Map<String, dynamic>);
      revision++;
      return http.Response(jsonEncode(body()), 200);
    }
    return http.Response('not found', 404);
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    StrategyConfig.instance.resetForTesting();
    dotenv.testLoad(fileInput: 'USE_MOCK_DATA=false\nDISABLE_MT5_BRIDGE=false\nBRIDGE_BASE_URL=http://bridge.test');
  });
  tearDown(() => StrategyConfig.instance.resetForTesting());

  Future<void> open(WidgetTester tester, _Bridge bridge) async {
    tester.view.physicalSize = const Size(800, 4200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final client = MockClient((request) async => bridge.handle(request));
    await tester.pumpWidget(MaterialApp(home: StrategyControlScreen(client: client)));
    await tester.pumpAndSettle();
  }

  group('control screen — market safety layers', () {
    testWidgets('both cross-engine layers show their mode and thresholds, defaulting to shadow', (tester) async {
      await open(tester, _Bridge());
      expect(find.text('Market safety layers'), findsOneWidget);
      expect(find.text('Fast-impulse guard (Range Bounce)'), findsOneWidget);
      expect(find.text('Volatility / chaos filter (all engines)'), findsOneWidget);
      expect(find.text('Shadow (log only)'), findsNWidgets(2));
      expect(find.byKey(const Key('filters.impulse.shock_atr')), findsOneWidget);
      expect(find.byKey(const Key('filters.chaos.pause_minutes')), findsOneWidget);
      // Rows that predate these layers may carry the "not applied yet" chip; the new ones must add none.
      final withLayers = tester.widgetList(find.text('not applied yet')).length;
      await open(tester, _Bridge(withLayers: false));
      expect(withLayers, tester.widgetList(find.text('not applied yet')).length,
          reason: 'every new setting is enforced by the engines');
    });

    testWidgets('switching the impulse guard to Block is saved as a nested filters patch', (tester) async {
      final bridge = _Bridge();
      await open(tester, bridge);
      await tester.ensureVisible(find.byKey(const Key('filters.impulse.mode')));
      await tester.tap(find.byKey(const Key('filters.impulse.mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Block').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-button')));
      await tester.pumpAndSettle();
      expect(bridge.updates.single['patch'], {
        'filters': {
          'impulse': {'mode': 'block'},
        },
      });
      expect(bridge.updates.single['confirm_risk_increase'], isFalse, reason: 'tightening needs no confirmation');
    });

    testWidgets('the chaos filter\'s mode is a separate setting', (tester) async {
      final bridge = _Bridge();
      await open(tester, bridge);
      await tester.ensureVisible(find.byKey(const Key('filters.chaos.mode')));
      await tester.tap(find.byKey(const Key('filters.chaos.mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Block').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-button')));
      await tester.pumpAndSettle();
      expect(bridge.updates.single['patch'], {
        'filters': {
          'chaos': {'mode': 'block'},
        },
      });
    });

    testWidgets('a bridge from before the layers existed shows no such section', (tester) async {
      await open(tester, _Bridge(withLayers: false));
      expect(find.text('Market safety layers'), findsNothing);
      expect(find.text('Fast-impulse guard (Range Bounce)'), findsNothing);
    });

    testWidgets('the ICT sweep alignment sits with the ICT engine\'s own thresholds', (tester) async {
      final bridge = _Bridge();
      await open(tester, bridge);
      await tester.ensureVisible(find.byKey(const Key('engine-ict')));
      await tester.tap(find.byKey(const Key('engine-ict')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('engine-ict-params')));
      await tester.tap(find.byKey(const Key('engine-ict-params')));
      await tester.pumpAndSettle();
      expect(find.text('Sweep alignment rule'), findsOneWidget);
      expect(find.text('shadow (log only)'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('engines.ict.params.sweep_mode')));
      await tester.tap(find.byKey(const Key('engines.ict.params.sweep_mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('block').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-button')));
      await tester.pumpAndSettle();
      expect(bridge.updates.single['patch'], {
        'engines': {
          'ict': {
            'params': {'sweep_mode': 'block'},
          },
        },
      });
    });
  });

  group('signal detail — shadow filters', () {
    TradeSetup setup({List<String> flags = const []}) => TradeSetup(
          symbol: 'XAUUSD',
          direction: TradeDirection.buy,
          timeframeLabel: '15M',
          setupType: SetupType.rangingBounce,
          entry: 2404.2,
          stopLoss: 2397.5,
          takeProfit: 2416.2,
          pattern: CandlePattern.bullishPinbar,
          detectedAt: DateTime.utc(2026, 9, 25, 14),
          outcome: TradeOutcome.win,
          shadowFlags: flags,
        );

    testWidgets('a flagged trade lists what the shadow layers would have blocked', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: SignalDetailScreen(
          setup: setup(flags: [
            'impulse_guard: bearish shock candle (4.2×ATR, M15) — counter-trend BUY restricted until 17:45 UTC',
            'chaos_filter: candle range 3.4× the 20-day median',
          ]),
        ),
      ));
      expect(find.byKey(const Key('shadow-flags')), findsOneWidget);
      expect(find.textContaining('Not enforced yet'), findsOneWidget);
      expect(find.textContaining('impulse_guard: bearish shock candle'), findsOneWidget);
      expect(find.textContaining('chaos_filter: candle range'), findsOneWidget);
    });

    testWidgets('an unflagged trade shows nothing of the sort', (tester) async {
      await tester.pumpWidget(MaterialApp(home: SignalDetailScreen(setup: setup())));
      expect(find.byKey(const Key('shadow-flags')), findsNothing);
    });
  });
}
