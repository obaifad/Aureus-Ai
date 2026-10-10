import 'package:aureus_ai/config/app_config.dart';
import 'package:aureus_ai/models/candle.dart';
import 'package:aureus_ai/models/pivot.dart';
import 'package:aureus_ai/services/signal_checker.dart';
import 'package:aureus_ai/services/strategy_config_service.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Asia ORB — the fifth engine since 2026-10-09, replacing the London/New York ORB. Pins the rules that were
/// replayed on real MT5 history: the 01:00-01:15 UTC range, a confirmed retest, entries only until 07:00 UTC, the
/// Stop Loss behind the range's far side, a 1:2 Take Profit, and no trend gate.
Candle _c(DateTime t, double o, double h, double l, double c) => Candle(time: t, open: o, high: h, low: l, close: c, volume: 1);

/// Range 01:00-01:15 UTC: high 4105, low 4095. Breakout candle 01:15 closes at 4107; retest candle 01:20 dips to
/// 4104.5 (touches the 4105 edge) and closes back above it at 4106 -> BUY at 4106.
List<Candle> _day({DateTime? breakoutAt}) {
  final d = DateTime.utc(2026, 10, 8);
  final b = breakoutAt ?? DateTime.utc(2026, 10, 8, 1, 15);
  return [
    _c(d.add(const Duration(hours: 1)), 4100, 4105, 4098, 4102),
    _c(d.add(const Duration(hours: 1, minutes: 5)), 4102, 4104, 4095, 4097),
    _c(d.add(const Duration(hours: 1, minutes: 10)), 4097, 4103, 4096, 4101),
    _c(b, 4101, 4108, 4100, 4107), // closes above 4105: breakout BUY
    _c(b.add(const Duration(minutes: 5)), 4107, 4107.5, 4104.5, 4106), // touches 4105, closes above: retest confirmed
  ];
}

StrategyConfigSnapshot _config({double? defaultRr, double? orbRr}) => StrategyConfigSnapshot.fromResponse({
      'revision': 9,
      'config': {
        'trade_rules': {'default_rr': defaultRr},
        'engines': {
          for (final id in EngineIds.all) id: {'rr': id == EngineIds.orb ? orbRr : null},
        },
      },
    });

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    dotenv.testLoad(fileInput: 'USE_MOCK_DATA=true');
    StrategyConfig.instance.resetForTesting();
  });
  tearDown(() => StrategyConfig.instance.resetForTesting());

  Future<(dynamic, List<String>)> evaluate({
    List<Candle>? candles,
    DateTime? now,
    TradeDirection? bias1h,
    double live = 4106.1,
  }) async {
    final at = now ?? DateTime.utc(2026, 10, 8, 1, 25, 5);
    final notes = <String>[];
    final setup = await SignalChecker(clock: () => at).debugEvaluateOrb(
      candles5m: candles ?? _day(),
      bias1h: bias1h,
      nowUtc: at,
      notes: notes,
      livePrice: live,
    );
    return (setup, notes);
  }

  test('fires a BUY on the confirmed retest: entry at the close, SL behind the far side, TP at exactly 2R', () async {
    StrategyConfig.instance.setSnapshot(_config(defaultRr: 1.8)); // the global default must NOT be used
    final (setup, notes) = await evaluate();
    expect(setup, isNotNull, reason: notes.join(' | '));
    expect(setup.setupType, SetupType.orbBreakout);
    expect(setup.direction, TradeDirection.buy);
    expect(setup.entry, 4106.0);
    expect(setup.stopLoss, closeTo(4095 - AppConfig.slBufferDollars, 1e-9));
    final risk = setup.entry - setup.stopLoss;
    expect(setup.takeProfit, closeTo(setup.entry + 2.0 * risk, 0.006));
    expect(AppConfig.orbRiskRewardDefault, 2.0);
  });

  test('the engine\'s own R:R in the bridge config still wins over the 1:2 default', () async {
    StrategyConfig.instance.setSnapshot(_config(defaultRr: 1.8, orbRr: 2.5));
    final (setup, _) = await evaluate();
    final risk = setup.entry - setup.stopLoss;
    expect(setup.takeProfit, closeTo(setup.entry + 2.5 * risk, 0.006));
  });

  test('no trend gate: a BUY against a bearish 1H bias still fires — the score just reads lower', () async {
    final (against, notes) = await evaluate(bias1h: TradeDirection.sell);
    expect(against, isNotNull, reason: notes.join(' | '));
    final (withTrend, _) = await evaluate(bias1h: TradeDirection.buy);
    expect(withTrend.confluenceScore, greaterThan(against.confluenceScore));
    expect(against.confluenceScore, greaterThanOrEqualTo(AppConfig.minConfluenceScoreOrb),
        reason: 'the score is informational and never rejects a setup that met the rules');
  });

  test('a breakout and retest after 07:00 UTC is never traded', () async {
    final late = _day(breakoutAt: DateTime.utc(2026, 10, 8, 7, 0));
    final (setup, notes) = await evaluate(candles: late, now: DateTime.utc(2026, 10, 8, 7, 10, 5));
    expect(setup, isNull);
    expect(notes.join(' '), contains('entry window closed at 07:00 UTC'));
  });

  test('the old London/New York hours are not traded: only the 01:00 UTC range exists', () async {
    final d = DateTime.utc(2026, 10, 8);
    final london = [
      for (final c in _day()) _c(c.time.add(const Duration(hours: 6)), c.open, c.high, c.low, c.close), // 07:00 range
    ];
    final (setup, notes) = await evaluate(candles: london, now: d.add(const Duration(hours: 7, minutes: 25, seconds: 5)));
    expect(setup, isNull);
    expect(notes.join(' '), contains('Asia'));
  });

  test('one trade per day: the same range does not fire twice', () async {
    final at = DateTime.utc(2026, 10, 8, 1, 25, 5);
    final checker = SignalChecker(clock: () => at);
    final first = await checker.debugEvaluateOrb(
        candles5m: _day(), bias1h: null, nowUtc: at, notes: <String>[], livePrice: 4106.1);
    expect(first, isNotNull);
    final notes = <String>[];
    final second = await checker.debugEvaluateOrb(
        candles5m: _day(), bias1h: null, nowUtc: at, notes: notes, livePrice: 4106.1);
    expect(second, isNull);
    expect(notes.join(' '), contains('range already traded today'));
  });

  test('a stop wider than the app\'s 200-pip limit is rejected, as in the replay', () async {
    final d = DateTime.utc(2026, 10, 8);
    final wide = [
      _c(d.add(const Duration(hours: 1)), 4100, 4105, 4098, 4102),
      _c(d.add(const Duration(hours: 1, minutes: 5)), 4102, 4104, 4080, 4097), // range low 4080 -> stop ~260 pips
      _c(d.add(const Duration(hours: 1, minutes: 10)), 4097, 4103, 4096, 4101),
      _c(d.add(const Duration(hours: 1, minutes: 15)), 4101, 4108, 4100, 4107),
      _c(d.add(const Duration(hours: 1, minutes: 20)), 4107, 4107.5, 4104.5, 4106),
    ];
    final (setup, notes) = await evaluate(candles: wide);
    expect(setup, isNull);
    expect(notes.join(' '), contains('SL distance above'));
  });
}
