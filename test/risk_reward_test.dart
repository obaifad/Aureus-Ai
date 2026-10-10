import 'package:aureus_ai/config/app_config.dart';
import 'package:aureus_ai/models/candle.dart';
import 'package:aureus_ai/models/pivot.dart';
import 'package:aureus_ai/models/trade_setup.dart';
import 'package:aureus_ai/services/risk_engine.dart';
import 'package:aureus_ai/services/signal_checker.dart';
import 'package:aureus_ai/services/strategy_config_service.dart';
import 'package:aureus_ai/services/zone_bounce_engine.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';

StrategyConfigSnapshot _config(
        {double? defaultRr, Map<String, double?> rr = const {}, Map<String, int> priority = const {}}) =>
    StrategyConfigSnapshot.fromResponse({
      'revision': 4,
      'config': {
        'trade_rules': {'default_rr': defaultRr},
        'engines': {
          for (final id in EngineIds.all) id: {'rr': rr[id], 'priority': priority[id]},
        },
      },
    });

Candle _c(int minute, double o, double h, double l, double c) =>
    Candle(time: DateTime.utc(2026, 10, 2, 9, minute), open: o, high: h, low: l, close: c, volume: 1);

void main() {
  setUp(() {
    dotenv.testLoad(fileInput: 'USE_MOCK_DATA=true');
    StrategyConfig.instance.resetForTesting();
  });
  tearDown(() => StrategyConfig.instance.resetForTesting());

  group('which reward-to-risk an engine uses', () {
    test('with no bridge config every engine uses the built-in 1.8', () {
      for (final id in EngineIds.all) {
        expect(AppConfig.rrFor(id), 1.8, reason: id);
      }
    });

    test('the config default replaces 1.8 for every engine without its own', () {
      StrategyConfig.instance.setSnapshot(_config(defaultRr: 2.2));
      for (final id in EngineIds.all) {
        expect(AppConfig.rrFor(id), 2.2, reason: id);
      }
    });

    test('an engine\'s own target beats the default, and only that engine is affected', () {
      StrategyConfig.instance.setSnapshot(_config(defaultRr: 2.2, rr: {EngineIds.orb: 3.0}));
      expect(AppConfig.rrFor(EngineIds.orb), 3.0);
      expect(AppConfig.rrFor(EngineIds.ict), 2.2);
    });

    test('clearing an engine\'s override (null) falls back to the default', () {
      StrategyConfig.instance.setSnapshot(_config(defaultRr: 2.0, rr: {EngineIds.orb: null}));
      expect(AppConfig.rrFor(EngineIds.orb), 2.0);
    });

    test('Breakout: the engine\'s config target wins, then BREAKOUT_TP_R, then the default', () {
      expect(AppConfig.breakoutTakeProfitRMultiple, 1.8);
      StrategyConfig.instance.setSnapshot(_config(defaultRr: 2.0));
      expect(AppConfig.breakoutTakeProfitRMultiple, 2.0);
      dotenv.testLoad(fileInput: 'USE_MOCK_DATA=true\nBREAKOUT_TP_R=1.5');
      expect(AppConfig.breakoutTakeProfitRMultiple, 1.5, reason: 'an explicit .env value beats the default');
      StrategyConfig.instance.setSnapshot(_config(defaultRr: 2.0, rr: {EngineIds.breakout: 2.5}));
      expect(AppConfig.breakoutTakeProfitRMultiple, 2.5);
    });
  });

  group('the target actually prices the trade', () {
    // Buy at 2405 with the stop 7.30 below at 2397.70.
    final candles = [
      _c(0, 2400, 2402, 2398.0, 2401),
      _c(15, 2401, 2406, 2399.0, 2405),
    ];
    const zone = SetupZone(type: SetupType.srBounce, zonePrice: 2399, candleIndex: 1);

    TradeSetup price({double? rr}) => RiskEngine().buildTradeSetup(
          candles: candles,
          zone: zone,
          pattern: CandlePattern.bullishPinbar,
          timeframeLabel: '15M',
          riskReward: rr,
        )!;

    test('without an explicit target the built-in 1.8 is used', () {
      final setup = price();
      expect(setup.entry, 2405);
      expect(setup.stopLoss, 2397.7);
      expect(setup.riskRewardRatio, closeTo(1.8, 0.01));
      expect(setup.takeProfit, closeTo(2405 + 1.8 * 7.3, 0.01));
    });

    test('a different target moves the take profit and nothing else', () {
      final setup = price(rr: 2.5);
      expect((setup.entry, setup.stopLoss), (2405, 2397.7));
      expect(setup.takeProfit, closeTo(2405 + 2.5 * 7.3, 0.01));
      expect(setup.riskRewardRatio, closeTo(2.5, 0.01));
    });

    test('Range Bounce prices its target from its own config and still never extends past the range', () {
      final trigger = ZoneBounceTrigger(
        zone: const HtfZone(price: 2399, source: '1H Support'),
        direction: TradeDirection.buy,
        rejectionCandle: candles.last,
        candleIndex: 1,
        pattern: CandlePattern.bullishPinbar,
        rejectionExtreme: 2399,
        rangeBoundary: null,
      );
      final engine = ZoneBounceEngine();
      expect(engine.takeProfitFor(trigger, entry: 2405, stopLoss: 2397.7), closeTo(2405 + 1.8 * 7.3, 0.001));

      StrategyConfig.instance.setSnapshot(_config(rr: {EngineIds.rangeBounce: 2.4}));
      expect(engine.takeProfitFor(trigger, entry: 2405, stopLoss: 2397.7), closeTo(2405 + 2.4 * 7.3, 0.001));

      final capped = ZoneBounceTrigger(
        zone: trigger.zone,
        direction: trigger.direction,
        rejectionCandle: trigger.rejectionCandle,
        candleIndex: 1,
        pattern: trigger.pattern,
        rejectionExtreme: 2399,
        rangeBoundary: 2415, // 1.37R away: nearer than the 2.4R target, so it clips
      );
      expect(engine.takeProfitFor(capped, entry: 2405, stopLoss: 2397.7), 2415);
    });
  });

  group('which engine wins when several fire at once', () {
    TradeSetup setup(SetupType type) => TradeSetup(
          symbol: 'XAUUSD',
          direction: TradeDirection.buy,
          timeframeLabel: '15M',
          setupType: type,
          entry: 2400,
          stopLoss: 2390,
          takeProfit: 2418,
          pattern: CandlePattern.bullishPinbar,
          detectedAt: DateTime.utc(2026, 10, 2, 9),
        );

    int rank(SignalChecker checker, SetupType type) => checker.debugPriorityRank(setup(type));

    test('with no config the built-in order applies: Top-Down, ICT, ICI, Range Bounce, ORB, Breakout', () {
      final checker = SignalChecker();
      final order = [
        SetupType.htfRetest,
        SetupType.ictLiquiditySweepReversal,
        SetupType.impulseCorrectionContinuation,
        SetupType.rangingBounce,
        SetupType.orbBreakout,
        SetupType.breakoutMomentum,
      ];
      final ranks = order.map((t) => rank(checker, t)).toList();
      expect(ranks, [...ranks]..sort());
      expect(ranks.toSet().length, 6);
    });

    test('the bridge config\'s priorities override that order', () {
      final checker = SignalChecker();
      StrategyConfig.instance.setSnapshot(_config(priority: {
        EngineIds.htfRetest: 6,
        EngineIds.ict: 5,
        EngineIds.orb: 4,
        EngineIds.ici: 3,
        EngineIds.breakout: 2,
        EngineIds.rangeBounce: 1,
      }));
      expect(rank(checker, SetupType.rangingBounce), lessThan(rank(checker, SetupType.htfRetest)));
      expect(rank(checker, SetupType.rangingBounce), 1);
      expect(rank(checker, SetupType.htfRetest), 6);
    });
  });
}
