import 'dart:convert';
import 'dart:math';

import 'package:aureus_ai/config/app_config.dart';
import 'package:aureus_ai/models/candle.dart';
import 'package:aureus_ai/models/pivot.dart';
import 'package:aureus_ai/models/trade_setup.dart';
import 'package:aureus_ai/services/app_logger.dart';
import 'package:aureus_ai/services/data_service.dart';
import 'package:aureus_ai/services/ict_engine.dart';
import 'package:aureus_ai/services/market_regime_guard.dart';
import 'package:aureus_ai/services/signal_checker.dart';
import 'package:aureus_ai/services/ta_engine.dart';
import 'package:aureus_ai/services/strategy_config_service.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Candle _c(DateTime t, double o, double h, double l, double c) => Candle(time: t, open: o, high: h, low: l, close: c, volume: 1);

/// The same market seen from the other side: every price p becomes [axis] - p, so a bullish sweep
/// reversal at a range low becomes a bearish one at a range high.
List<Candle> _mirror(List<Candle> candles, {double axis = 4810}) =>
    [for (final c in candles) _c(c.time, axis - c.open, axis - c.low, axis - c.high, axis - c.close)];

/// 15M market ranging between ~2395 and ~2409 (12-candle cycle), then a hand-built ending: a lower high,
/// a drop to a valley, a SWEEP candle under it, and a displacement candle closing through the range high
/// — an ICT Liquidity-Sweep Reversal BUY with a bullish engulfing confirmation.
///
/// [sweep] / [displacement] override the last two candles (open, high, low, close).
List<Candle> _rangeSweepMarket({List<double>? sweep, List<double>? displacement}) {
  final start = DateTime.utc(2026, 10, 6, 0);
  final out = <Candle>[];
  var prev = 2402.0;
  for (var i = 0; i < 56; i++) {
    final close = 2402 + 6 * sin(2 * pi * i / 12) + ((i * 37) % 7) * 0.07;
    final hi = max(prev, close) + 0.6 + ((i * 13) % 5) * 0.05;
    final lo = min(prev, close) - 0.6 - ((i * 17) % 5) * 0.05;
    out.add(_c(start.add(Duration(minutes: 15 * i)), prev, hi, lo, close));
    prev = close;
  }
  final tail = <List<double>>[
    [prev, prev + 1.2, prev - 0.3, prev + 1.0],
    [2403.0, 2404.4, 2402.4, 2403.9],
    [2403.9, 2404.0, 2401.0, 2401.5],
    [2401.5, 2401.8, 2398.9, 2399.2],
    [2399.2, 2399.5, 2396.9, 2397.4], // valley
    [2397.4, 2398.9, 2397.0, 2398.5],
    [2398.5, 2399.0, 2397.6, 2398.0],
    sweep ?? [2398.0, 2398.3, 2393.2, 2397.6], // wicks under the valley and the range low, closes back above
    displacement ?? [2397.5, 2411.5, 2397.3, 2410.8], // closes through the range high
  ];
  final t = out.last.time;
  for (var k = 0; k < tail.length; k++) {
    final o = tail[k];
    out.add(_c(t.add(Duration(minutes: 15 * (k + 1))), o[0], o[1], o[2], o[3]));
  }
  return out;
}

/// 60 H1 candles zig-zagging with rising (buy), falling (sell) or flat (null) swing highs and lows, so
/// IctEngine.structureBias reads a clear bias or none; the 1H equilibrium sits well above 2411 (a BUY is
/// in "discount"). [mirrored] flips it for the SELL scenarios.
List<Candle> _htfSeries(TradeDirection? wanted, {bool mirrored = false}) {
  // [wanted] is the bias the engine should READ; mirroring flips a structure, so build the opposite one.
  final bias = !mirrored || wanted == null ? wanted : (wanted == TradeDirection.buy ? TradeDirection.sell : TradeDirection.buy);
  final List<double> highs = switch (bias) {
    TradeDirection.buy => [2440, 2450, 2460, 2470, 2480, 2490],
    TradeDirection.sell => [2490, 2480, 2470, 2460, 2450, 2440],
    null => [2450, 2450, 2450, 2450, 2450, 2450],
  };
  final List<double> lows = switch (bias) {
    TradeDirection.buy => [2400, 2410, 2420, 2430, 2440, 2450],
    TradeDirection.sell => [2450, 2440, 2430, 2420, 2410, 2400],
    null => [2400, 2400, 2400, 2400, 2400, 2400],
  };
  final List<double> points = [for (var i = 0; i < 6; i++) ...[lows[i], highs[i]]];
  final out = <Candle>[];
  var prev = points.first;
  final start = DateTime.utc(2026, 9, 25);
  for (var leg = 0; leg < points.length - 1; leg++) {
    final from = points[leg], to = points[leg + 1];
    for (var j = 1; j <= 5; j++) {
      final close = from + (to - from) * j / 5;
      final lastOfLeg = j == 5;
      final up = to > from;
      final high = max(prev, close) + (lastOfLeg && up ? 0.6 : 0.3);
      final low = min(prev, close) - (lastOfLeg && !up ? 0.6 : 0.3);
      out.add(_c(start.add(Duration(hours: out.length)), prev, high, low, close));
      prev = close;
    }
  }
  final series = out.sublist(out.length - 50);
  return mirrored ? _mirror(series, axis: 4800) : series;
}

const _support = HtfZone(price: 2396.0, source: '1H Support');
const _resistance = HtfZone(price: 2414.0, source: '1H Resistance'); // 4810 - 2396

/// A zone-bounce market: quiet candles above 2400, then a pin-bar rejection off a level that holds.
List<Candle> _bounceMarket() {
  final base = DateTime.utc(2026, 9, 25, 8);
  return [
    for (var i = 0; i < 24; i++) _c(base.add(Duration(minutes: 15 * i)), 2406, 2408, 2404, 2406),
    _c(base.add(const Duration(hours: 6)), 2403, 2404.5, 2398.5, 2404.2),
  ];
}

ImpulseEvent _impulse(TradeDirection direction, {ImpulseKind kind = ImpulseKind.shockCandle}) => ImpulseEvent(
      direction: direction,
      kind: kind,
      timeframe: 'M15',
      endsAt: DateTime.utc(2026, 9, 25, 13, 45),
      restrictUntil: DateTime.utc(2026, 9, 25, 17, 45),
      magnitudeAtr: 4.2,
    );

StrategyConfigSnapshot _snapshot(Map<String, dynamic> config, {int revision = 5}) => StrategyConfigSnapshot(revision, config);

Map<String, dynamic> _modes({String? impulse, String? chaos, String? sweep}) => {
      'filters': {
        if (impulse != null) 'impulse': {'mode': impulse},
        if (chaos != null) 'chaos': {'mode': chaos},
      },
      if (sweep != null)
        'engines': {
          'ict': {
            'params': {'sweep_mode': sweep}
          }
        },
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    StrategyConfig.instance.resetForTesting();
    dotenv.testLoad(fileInput: 'USE_MOCK_DATA=true');
  });
  tearDown(() => StrategyConfig.instance.resetForTesting());

  group('GuardMode and the config that drives it', () {
    test('every layer is SHADOW with no bridge config — never block', () {
      expect(AppConfig.impulseGuardMode, GuardMode.shadow);
      expect(AppConfig.chaosFilterMode, GuardMode.shadow);
      expect(AppConfig.ictSweepMode, GuardMode.shadow);
    });

    test('an unknown, empty or mistyped mode is shadow, not block', () {
      for (final raw in [null, '', 'enforce', 'BLOCKED', 'true', ' ']) {
        expect(GuardMode.parse(raw), GuardMode.shadow, reason: '$raw');
      }
      expect(GuardMode.parse('block'), GuardMode.block);
      expect(GuardMode.parse(' Block '), GuardMode.block);
      expect(GuardMode.parse('OFF'), GuardMode.off);
    });

    test('the bridge config sets each layer\'s mode', () {
      StrategyConfig.instance.setSnapshot(_snapshot(_modes(impulse: 'block', chaos: 'off', sweep: 'block')));
      expect(AppConfig.impulseGuardMode, GuardMode.block);
      expect(AppConfig.chaosFilterMode, GuardMode.off);
      expect(AppConfig.ictSweepMode, GuardMode.block);
    });

    test('thresholds default to the specification and follow the bridge when it has them', () {
      expect(
        (AppConfig.impulseConsecutive, AppConfig.impulseShockAtr, AppConfig.impulseMinHours, AppConfig.impulseMaxHours),
        (3, 3.0, 2.0, 4.0),
      );
      expect((AppConfig.chaosBaselineDays, AppConfig.chaosRangeMult, AppConfig.chaosPauseMinutes), (20, 3.0, 15));
      expect((AppConfig.ictSweepRangeLookback, AppConfig.ictSweepBoundaryAtr), (48, 0.5));
      StrategyConfig.instance.setSnapshot(_snapshot({
        'filters': {
          'impulse': {'consecutive': 4, 'shock_atr': 2.5, 'max_hours': 3.0},
          'chaos': {'range_mult': 4.0, 'baseline_days': 10, 'pause_minutes': 30},
        },
        'engines': {
          'ict': {
            'params': {'sweep_range_lookback': 96, 'sweep_boundary_atr': 0.25}
          }
        },
      }));
      expect((AppConfig.impulseConsecutive, AppConfig.impulseShockAtr, AppConfig.impulseMaxHours), (4, 2.5, 3.0));
      expect((AppConfig.chaosRangeMult, AppConfig.chaosBaselineDays, AppConfig.chaosPauseMinutes), (4.0, 10, 30));
      expect((AppConfig.ictSweepRangeLookback, AppConfig.ictSweepBoundaryAtr), (96, 0.25));
      final params = ImpulseParams.current();
      expect((params.consecutive, params.shockAtr, params.maxHours), (4, 2.5, 3.0));
    });

    test('changing a mode does not touch any risk setting the snapshot carries', () {
      final risk = {
        'mode': {'auto_trade': 'auto'},
        'account_limits': {'lot_mode': 'fixed', 'fixed_lot_size': 0.1, 'max_daily_loss_percent': 5.0, 'entry_drift_chase_r': 0.25},
      };
      StrategyConfig.instance.setSnapshot(_snapshot({...risk, ..._modes(impulse: 'block', chaos: 'block', sweep: 'block')}));
      final s = StrategyConfig.instance.current;
      expect(s.autoTradeMode, 'auto');
      expect((s.lotMode, s.fixedLotSize), ('fixed', 0.1));
      expect(s.filterNum('impulse', 'consecutive'), isNull, reason: 'absent values stay null, they are not invented');
    });
  });

  group('TradeSetup.shadowFlags', () {
    TradeSetup setup() => TradeSetup(
          symbol: 'XAUUSD',
          direction: TradeDirection.buy,
          timeframeLabel: '15M',
          setupType: SetupType.rangingBounce,
          entry: 2404.2,
          stopLoss: 2397.5,
          takeProfit: 2416.2,
          pattern: CandlePattern.bullishPinbar,
          detectedAt: DateTime.utc(2026, 9, 25, 14),
        );

    test('a setup nobody objected to carries no flags and no key', () {
      final s = setup();
      expect(s.shadowFlags, isEmpty);
      expect(s.toJson().containsKey('shadow_flags'), isFalse);
    });

    test('flags survive a JSON round trip, in order', () {
      final s = setup()
        ..addShadowFlag('${ShadowLayer.impulse}: bearish shock candle')
        ..addShadowFlag('${ShadowLayer.chaos}: spread 9 pips');
      final back = TradeSetup.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
      expect(back.shadowFlags, ['${ShadowLayer.impulse}: bearish shock candle', '${ShadowLayer.chaos}: spread 9 pips']);
    });

    test('a setup persisted before the flags existed loads with none', () {
      final json = setup().toJson()..remove('shadow_flags');
      expect(TradeSetup.fromJson(json).shadowFlags, isEmpty);
    });

    test('adding a flag never mutates a list another setup shares', () {
      final a = setup();
      final b = setup();
      a.addShadowFlag('x');
      expect(b.shadowFlags, isEmpty);
    });
  });

  group('IctEngine.assessSweepAlignment', () {
    final engine = IctEngine();

    SweepAlignment assess(List<Candle> m15, TradeDirection dir, {TradeDirection? bias, SweepAlignmentParams? params}) =>
        engine.assessSweepAlignment(candles: m15, direction: dir, htfBias: bias, params: params ?? const SweepAlignmentParams());

    test('with no clear bias a sweep of the range LOW is a liquidity grab at the boundary: allowed', () {
      final a = assess(_rangeSweepMarket(), TradeDirection.buy);
      expect(a.kind, SweepAlignmentKind.rangeBoundary);
      expect(a.allowed, isTrue);
      expect(a.detail, allOf(contains('range low'), contains('2395.20')));
    });

    test('the mirror image — a sweep of the range HIGH — is allowed for a SELL', () {
      final a = assess(_mirror(_rangeSweepMarket()), TradeDirection.sell);
      expect(a.kind, SweepAlignmentKind.rangeBoundary);
      expect(a.detail, contains('range high'));
    });

    test('a reversal that agrees with the 4H+1H structure bias is allowed wherever it happens', () {
      final a = assess(_rangeSweepMarket(), TradeDirection.buy, bias: TradeDirection.buy);
      expect((a.kind, a.allowed), (SweepAlignmentKind.alignedWithBias, true));
      expect(a.detail, contains('agrees'));
    });

    test('a reversal AGAINST a clear bias is never allowed — even right at the range low', () {
      final a = assess(_rangeSweepMarket(), TradeDirection.buy, bias: TradeDirection.sell);
      expect((a.kind, a.allowed), (SweepAlignmentKind.counterTrend, false));
      expect(a.detail, allOf(contains('against'), contains('bearish')));
      final sell = assess(_mirror(_rangeSweepMarket()), TradeDirection.sell, bias: TradeDirection.buy);
      expect(sell.kind, SweepAlignmentKind.counterTrend);
    });

    test('sweeping an INTERNAL low is not a boundary grab', () {
      final market = _rangeSweepMarket(
        sweep: [2399.6, 2399.9, 2398.4, 2399.0],
        displacement: [2398.9, 2411.5, 2398.7, 2410.8],
      );
      final a = assess(market, TradeDirection.buy);
      expect(a.kind, SweepAlignmentKind.notAtBoundary);
      expect(a.detail, allOf(contains('short of the range low'), contains('2395.20')));
    });

    test('the boundary tolerance is the config\'s: the same sweep passes with a wide enough one', () {
      final market = _rangeSweepMarket(
        sweep: [2399.6, 2399.9, 2398.4, 2399.0],
        displacement: [2398.9, 2411.5, 2398.7, 2410.8],
      );
      expect(assess(market, TradeDirection.buy, params: const SweepAlignmentParams(boundaryAtr: 1.2)).allowed, isTrue);
    });

    test('a market that trended into the sweep is not a range', () {
      final start = DateTime.utc(2026, 10, 6);
      final candles = <Candle>[];
      var prev = 2480.0;
      for (var i = 0; i < 56; i++) {
        final close = 2480 - 2.0 * i + 4 * sin(2 * pi * i / 8) + ((i * 37) % 7) * 0.07;
        candles.add(_c(start.add(Duration(minutes: 15 * i)), prev, max(prev, close) + 0.6 + ((i * 13) % 5) * 0.05,
            min(prev, close) - 0.6 - ((i * 17) % 5) * 0.05, close));
        prev = close;
      }
      // sweep the most recent confirmed swing low: wick under it, close back above it
      final pivot = TaEngine().findPivots(candles).where((p) => p.type == PivotType.low).last;
      candles.add(_c(start.add(const Duration(minutes: 15 * 56)), pivot.price + 0.2, pivot.price + 1.3, pivot.price - 1.5, pivot.price + 0.8));
      final a = assess(candles, TradeDirection.buy);
      expect(a.kind, SweepAlignmentKind.notAtBoundary);
      expect(a.detail, contains('trended'));
    });

    test('a band no taller than ~2 ATR is noise, not a range', () {
      final start = DateTime.utc(2026, 10, 6);
      final candles = <Candle>[
        for (var i = 0; i < 60; i++)
          _c(start.add(Duration(minutes: 15 * i)), 2400 + (i.isEven ? 0.3 : -0.3), 2405 + (i % 4) * 0.1, 2395 - (i % 3) * 0.1,
              2400 + (i.isEven ? -0.3 : 0.3)),
      ];
      final t = candles.last.time;
      candles
        ..add(_c(t.add(const Duration(minutes: 15)), 2400, 2405.5, 2394.0, 2398)) // a deeper low than any pivot
        ..add(_c(t.add(const Duration(minutes: 30)), 2398, 2405, 2396, 2402));
      final a = assess(candles, TradeDirection.buy);
      expect(a.kind, SweepAlignmentKind.notAtBoundary);
    });

    test('with no sweep at all there is nothing to call a boundary grab', () {
      final quiet = [for (var i = 0; i < 40; i++) _c(DateTime.utc(2026, 10, 6).add(Duration(minutes: 15 * i)), 2400, 2401, 2399, 2400.2)];
      expect(assess(quiet, TradeDirection.buy).kind, SweepAlignmentKind.notAtBoundary);
    });
  });

  group('IctEngine.findTrigger with the realignment enforced', () {
    final engine = IctEngine();
    const params = SweepAlignmentParams();

    IctTriggerResult? find(List<Candle> m15, TradeDirection? bias, {bool enforce = false, List<SweepAlignment>? rejected, bool mirrored = false}) =>
        engine.findTrigger(
          candles15m: m15,
          candles1h: _htfSeries(bias, mirrored: mirrored),
          candles4h: _htfSeries(bias, mirrored: mirrored),
          htfZones: [mirrored ? _resistance : _support],
          enforceSweepAlignment: enforce ? params : null,
          onSweepRejected: rejected?.add,
        );

    test('the scenario fires a Liquidity-Sweep Reversal when nothing is enforced (today\'s behaviour)', () {
      for (final bias in [null, TradeDirection.buy, TradeDirection.sell]) {
        final t = find(_rangeSweepMarket(), bias);
        expect(t?.trigger.type, SetupType.ictLiquiditySweepReversal, reason: 'bias $bias');
      }
    });

    test('enforced: a counter-trend reversal is skipped, and the rejection is reported', () {
      final rejected = <SweepAlignment>[];
      expect(find(_rangeSweepMarket(), TradeDirection.sell, enforce: true, rejected: rejected), isNull);
      expect(rejected.single.kind, SweepAlignmentKind.counterTrend);
    });

    test('enforced: a range-boundary grab with no clear bias still fires', () {
      final rejected = <SweepAlignment>[];
      final t = find(_rangeSweepMarket(), null, enforce: true, rejected: rejected);
      expect(t?.trigger.type, SetupType.ictLiquiditySweepReversal);
      expect(rejected, isEmpty);
    });

    test('enforced: a reversal WITH the bias still fires', () {
      expect(find(_rangeSweepMarket(), TradeDirection.buy, enforce: true)?.trigger.type, SetupType.ictLiquiditySweepReversal);
    });

    test('enforced: with no bias, an internal-low sweep is skipped', () {
      final market = _rangeSweepMarket(
        sweep: [2399.6, 2399.9, 2398.4, 2399.0],
        displacement: [2398.9, 2411.5, 2398.7, 2410.8],
      );
      expect(find(market, null)?.trigger.type, SetupType.ictLiquiditySweepReversal, reason: 'it fires today');
      final rejected = <SweepAlignment>[];
      expect(find(market, null, enforce: true, rejected: rejected), isNull);
      expect(rejected.single.kind, SweepAlignmentKind.notAtBoundary);
    });

    test('enforced: the SELL side behaves the same way', () {
      final market = _mirror(_rangeSweepMarket());
      expect(find(market, null, enforce: true, mirrored: true)?.trigger.type, SetupType.ictLiquiditySweepReversal);
      final rejected = <SweepAlignment>[];
      expect(find(market, TradeDirection.buy, enforce: true, rejected: rejected, mirrored: true), isNull);
      expect(rejected.single.kind, SweepAlignmentKind.counterTrend);
    });
  });

  group('ICT evaluator — shadow / block / off', () {
    final now = DateTime.utc(2026, 10, 6, 16, 5);

    Future<({TradeSetup? setup, List<String> notes, SignalChecker checker})> run(
      TradeDirection? bias, {
      String? sweepMode,
      List<Candle>? m15,
    }) async {
      StrategyConfig.instance.setSnapshot(_snapshot(_modes(sweep: sweepMode)));
      final checker = SignalChecker(clock: () => now);
      final notes = <String>[];
      final htf = _htfSeries(bias);
      final setup = await checker.debugEvaluateIct(
        m15: m15 ?? _rangeSweepMarket(),
        h1: htf,
        h4: htf,
        htfZones: [_support],
        notes: notes,
        livePrice: 2410.8,
      );
      return (setup: setup, notes: notes, checker: checker);
    }

    test('SHADOW (the default): a counter-trend reversal is still traded, and carries the flag', () async {
      final r = await run(TradeDirection.sell);
      expect(r.setup?.setupType, SetupType.ictLiquiditySweepReversal);
      expect(r.setup!.shadowFlags.single, allOf(startsWith('${ShadowLayer.ictSweep}: '), contains('against the bearish')));
      expect(AppLogger.entries.where((l) => l.contains('[SHADOW] [ICT]') && l.contains('would have been rejected')), isNotEmpty);
    });

    test('SHADOW: a reversal the rule accepts is not flagged', () async {
      expect((await run(null)).setup!.shadowFlags, isEmpty); // range-boundary grab
      expect((await run(TradeDirection.buy)).setup!.shadowFlags, isEmpty); // with the bias
    });

    test('SHADOW: an internal-low sweep with no bias is flagged', () async {
      final market = _rangeSweepMarket(sweep: [2399.6, 2399.9, 2398.4, 2399.0], displacement: [2398.9, 2411.5, 2398.7, 2410.8]);
      final r = await run(null, m15: market);
      expect(r.setup!.shadowFlags.single, contains('short of the range low'));
    });

    test('OFF: nothing is evaluated and nothing is flagged', () async {
      final r = await run(TradeDirection.sell, sweepMode: 'off');
      expect(r.setup?.setupType, SetupType.ictLiquiditySweepReversal);
      expect(r.setup!.shadowFlags, isEmpty);
    });

    test('BLOCK: the counter-trend reversal is rejected, with the reason in the scan notes', () async {
      final r = await run(TradeDirection.sell, sweepMode: 'block');
      expect(r.setup, isNull);
      expect(r.notes.join(' | '), allOf(contains('Liquidity-Sweep Reversal rejected'), contains('against the bearish')));
    });

    test('BLOCK: a rejected reversal burns no ICT debounce state, so a later valid one is not suppressed', () async {
      final blocked = await run(TradeDirection.sell, sweepMode: 'block');
      final untouched = blocked.checker.debugCaptureState(EngineIds.ict);
      expect(untouched['candle'], isNull);
      expect((untouched['zones'] as Map).isEmpty, isTrue);
      // the very same candles with the bias gone now fire on the same checker
      final htf = _htfSeries(null);
      final again = await blocked.checker.debugEvaluateIct(
        m15: _rangeSweepMarket(),
        h1: htf,
        h4: htf,
        htfZones: [_support],
        notes: [],
        livePrice: 2410.8,
      );
      expect(again?.setupType, SetupType.ictLiquiditySweepReversal);
    });

    test('BLOCK: an allowed reversal fires with no flag', () async {
      final r = await run(null, sweepMode: 'block');
      expect(r.setup?.setupType, SetupType.ictLiquiditySweepReversal);
      expect(r.setup!.shadowFlags, isEmpty);
    });
  });

  group('Range Bounce evaluator — Fast-Impulse Guard', () {
    final now = DateTime.utc(2026, 9, 25, 14, 5);

    Future<({TradeSetup? setup, List<String> notes, SignalChecker checker})> run(
      GuardMode mode,
      ImpulseVerdict verdict, {
      SignalChecker? checker,
    }) async {
      final c = checker ?? SignalChecker(clock: () => now);
      final notes = <String>[];
      final setup = await c.debugEvaluateZoneBounce(
        m15: _bounceMarket(),
        htfZones: const [HtfZone(price: 2400, source: '15M Support')],
        notes: notes,
        livePrice: 2404.2,
        impulse: verdict,
        impulseMode: mode,
      );
      return (setup: setup, notes: notes, checker: c);
    }

    final againstTrade = ImpulseVerdict([_impulse(TradeDirection.sell)]); // a BUY is the counter-trend trade
    final withTrade = ImpulseVerdict([_impulse(TradeDirection.buy)]);

    test('with no impulse the engine fires as it always did', () async {
      final r = await run(GuardMode.block, ImpulseVerdict.none);
      expect(r.setup?.direction, TradeDirection.buy);
      expect(r.setup!.shadowFlags, isEmpty);
    });

    test('OFF ignores even a counter-trend impulse', () async {
      final r = await run(GuardMode.off, againstTrade);
      expect(r.setup, isNotNull);
      expect(r.setup!.shadowFlags, isEmpty);
    });

    test('SHADOW: the counter-trend BUY is traded but flagged with the impulse and when it lifts', () async {
      final r = await run(GuardMode.shadow, againstTrade);
      expect(r.setup, isNotNull);
      final flag = r.setup!.shadowFlags.single;
      expect(flag, allOf(startsWith('${ShadowLayer.impulse}: '), contains('bearish shock candle'), contains('restricted until 17:45 UTC')));
      expect(r.notes.where((n) => n.contains('Fast-Impulse')), isEmpty, reason: 'shadow adds nothing to the scan status');
      expect(AppLogger.entries.where((l) => l.contains('[SHADOW] [Range] Fast-Impulse Guard would have rejected')), isNotEmpty);
    });

    test('BLOCK: the counter-trend BUY is rejected', () async {
      final r = await run(GuardMode.block, againstTrade);
      expect(r.setup, isNull);
      expect(r.notes.join(' | '), allOf(contains('Fast-Impulse Guard'), contains('counter-trend BUY')));
    });

    test('a trade WITH the impulse is never restricted, in any mode', () async {
      for (final mode in GuardMode.values) {
        final r = await run(mode, withTrade);
        expect(r.setup, isNotNull, reason: '$mode');
        expect(r.setup!.shadowFlags, isEmpty, reason: '$mode');
      }
    });

    test('BLOCK burns no cooldown: once the impulse lifts, the very same setup fires', () async {
      final blocked = await run(GuardMode.block, againstTrade);
      expect(blocked.setup, isNull);
      expect(blocked.checker.debugCaptureState(EngineIds.rangeBounce)['candle'], isNull);
      final later = await run(GuardMode.block, ImpulseVerdict.none, checker: blocked.checker);
      expect(later.setup?.direction, TradeDirection.buy);
    });

    test('a verdict with impulses both ways restricts both directions', () async {
      final both = ImpulseVerdict([_impulse(TradeDirection.sell), _impulse(TradeDirection.buy)]);
      expect((await run(GuardMode.block, both)).setup, isNull);
    });
  });

  group('Chaos filter inside the scan', () {
    // 21 calm trading days of 15M ($6 ranges), then today up to 10:00; the 09:45 candle is the one under test.
    final now = DateTime.utc(2026, 9, 22, 10, 7);
    List<Candle> m15({required double lastRange}) {
      final out = <Candle>[];
      for (var d = 0; d < 21; d++) {
        for (var s = 0; s < 96; s++) {
          out.add(_c(DateTime.utc(2026, 9, 1 + d).add(Duration(minutes: 15 * s)), 2400, 2406, 2400, 2403));
        }
      }
      final today = DateTime.utc(2026, 9, 22);
      for (var s = 0; s <= 40; s++) {
        final isLastClosed = s == 39;
        out.add(_c(today.add(Duration(minutes: 15 * s)), 2400, 2400 + (isLastClosed ? lastRange : 6), 2400, 2403));
      }
      return out;
    }

    List<Candle> flat(int tfMinutes, int count) => [
          for (var i = 0; i < count; i++)
            _c(DateTime.utc(2026, 9, 22, 10).subtract(Duration(minutes: tfMinutes * (count - i))), 2400, 2402, 2398, 2400),
        ];

    Future<({SignalCheckResult result, List<(int, int)> requests, SignalChecker checker})> scan(
      double lastRange, {
      String? chaosMode,
    }) async {
      dotenv.testLoad(fileInput: 'USE_MOCK_DATA=false\nDISABLE_MT5_BRIDGE=true');
      StrategyConfig.instance.setSnapshot(_snapshot(_modes(chaos: chaosMode)));
      final data = _FakeData(m15: m15(lastRange: lastRange), h1: flat(60, 80), h4: flat(240, 80));
      final checker = SignalChecker(clock: () => now, dataServiceFactory: () => data);
      final result = await checker.check();
      return (result: result, requests: data.requests, checker: checker);
    }

    test('BLOCK pauses every engine while a candle is 3x its time-of-day median, and says why', () async {
      final r = await scan(30, chaosMode: 'block');
      expect(r.result.setups, isEmpty);
      expect(r.result.status, allOf(contains('Chaos filter'), contains('all engines paused'), contains('5.0×')));
      expect(r.result.status, isNot(contains('Key Zones')), reason: 'the scan stopped before any engine work');
      expect(AppLogger.entries.where((l) => l.contains('Chaos filter PAUSE')), isNotEmpty);
    });

    test('BLOCK lets the scan through once the market is normal again', () async {
      final r = await scan(6, chaosMode: 'block');
      expect(r.result.status, isNot(contains('Chaos filter')));
      expect(r.result.status, contains('No HTF Key Zones'), reason: 'the scan went on to the engines');
    });

    test('SHADOW (the default) never pauses: the engines run and the would-be pause is only logged', () async {
      final r = await scan(30);
      expect(r.result.status, isNot(contains('all engines paused')));
      expect(r.result.status, contains('No HTF Key Zones'));
      expect(AppLogger.entries.where((l) => l.contains('[SHADOW] Chaos filter would have paused all engines')), isNotEmpty);
    });

    test('OFF fetches no baseline at all and logs nothing', () async {
      final before = AppLogger.entries.length;
      final r = await scan(30, chaosMode: 'off');
      expect(r.result.status, contains('No HTF Key Zones'));
      expect(r.requests.where((q) => q.$2 == 2000), isEmpty);
      expect(AppLogger.entries.skip(before).where((l) => l.contains('Chaos filter') || l.contains('Volatility baseline')), isEmpty);
    });

    test('the baseline is one long fetch, reused on the next scan', () async {
      final r = await scan(30, chaosMode: 'block');
      expect(r.requests.where((q) => q == (15, 2000)).length, 1);
      await r.checker.check();
      // the second scan's data service is the same fake: still exactly one long fetch overall
      expect(r.requests.where((q) => q == (15, 2000)).length, 1);
    });

    test('mock data is never judged: its history is random, so there is nothing to compare with', () async {
      dotenv.testLoad(fileInput: 'USE_MOCK_DATA=true');
      StrategyConfig.instance.setSnapshot(_snapshot(_modes(chaos: 'block')));
      final result = await SignalChecker().check();
      expect(result.status, isNot(contains('Chaos filter')));
    });

    test('no usable history means no opinion: a failed baseline fetch never blocks', () async {
      dotenv.testLoad(fileInput: 'USE_MOCK_DATA=false\nDISABLE_MT5_BRIDGE=true');
      StrategyConfig.instance.setSnapshot(_snapshot(_modes(chaos: 'block')));
      final data = _FakeData(m15: m15(lastRange: 30), h1: flat(60, 80), h4: flat(240, 80), failLongFetch: true);
      final result = await SignalChecker(clock: () => now, dataServiceFactory: () => data).check();
      expect(result.status, isNot(contains('all engines paused')));
      expect(AppLogger.entries.where((l) => l.contains('Volatility baseline unavailable')), isNotEmpty);
    });
  });
}

class _FakeData implements DataService {
  _FakeData({required this.m15, required this.h1, required this.h4, this.failLongFetch = false});
  final List<Candle> m15, h1, h4;
  final bool failLongFetch;
  final List<(int, int)> requests = [];

  @override
  Future<List<Candle>> getCandles({required int timeframeMinutes, int count = 300, String? symbol}) async {
    requests.add((timeframeMinutes, count));
    if (failLongFetch && count >= 2000) throw DataServiceException('simulated outage');
    final source = switch (timeframeMinutes) {
      15 => m15,
      60 => h1,
      240 => h4,
      _ => const <Candle>[],
    };
    return source.length <= count ? source : source.sublist(source.length - count);
  }
}
