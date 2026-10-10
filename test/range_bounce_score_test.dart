import 'package:aureus_ai/config/app_config.dart';
import 'package:aureus_ai/models/candle.dart';
import 'package:aureus_ai/models/pivot.dart';
import 'package:aureus_ai/models/trade_setup.dart';
import 'package:aureus_ai/services/signal_checker.dart';
import 'package:aureus_ai/services/strategy_config_service.dart';
import 'package:aureus_ai/services/zone_bounce_engine.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Candle _c(DateTime t, double o, double h, double l, double c) => Candle(time: t, open: o, high: h, low: l, close: c, volume: 1);

/// Quiet candles above 2400, then a pin-bar rejection off a level that holds (the same market the engine tests use).
List<Candle> _bounceMarket() {
  final base = DateTime.utc(2026, 9, 25, 8);
  return [
    for (var i = 0; i < 24; i++) _c(base.add(Duration(minutes: 15 * i)), 2406, 2408, 2404, 2406),
    _c(base.add(const Duration(hours: 6)), 2403, 2404.5, 2398.5, 2404.2),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    StrategyConfig.instance.resetForTesting();
    dotenv.testLoad(fileInput: 'USE_MOCK_DATA=true');
  });
  tearDown(() => StrategyConfig.instance.resetForTesting());

  Future<({TradeSetup? setup, List<String> notes})> evaluate(List<HtfZone> zones, {DateTime? at, SignalChecker? checker, List<Candle>? candles, double livePrice = 2404.2}) async {
    checker ??= SignalChecker(clock: () => at ?? DateTime.utc(2026, 9, 25, 14, 5));
    final notes = <String>[];
    final setup = await checker.debugEvaluateZoneBounce(
      m15: candles ?? _bounceMarket(),
      htfZones: zones,
      notes: notes,
      livePrice: livePrice,
    );
    return (setup: setup, notes: notes);
  }

  group('Range Bounce trades 15M levels only', () {
    test('a bounce off a 15M level fires, with the full zone weight in its Confluence Score', () async {
      final r = await evaluate(const [HtfZone(price: 2400, source: '15M Support')]);
      expect(r.setup, isNotNull);
      // pin bar 22 + zone 30 + wick 1.5 into the level (capped) 20 + room to the target 20
      expect(r.setup!.confluenceScore, 22 + 30 + 20 + 20);
      expect(r.setup!.direction, TradeDirection.buy);
    });

    test('15M trendlines and resistances count as 15M levels', () async {
      expect((await evaluate(const [HtfZone(price: 2400, source: '15M Trendline (ascending)')])).setup, isNotNull);
      expect((await evaluate(const [HtfZone(price: 2400, source: '15M Resistance')])).setup, isNotNull);
    });

    test('the very same bounce off a 1H or 4H level is NOT taken, and the scan says why', () async {
      for (final source in ['1H Support', '4H Support', '1H Trendline (ascending)', '4H Resistance']) {
        final r = await evaluate([HtfZone(price: 2400, source: source)]);
        expect(r.setup, isNull, reason: source);
        expect(r.notes.join(' | '), contains('nearest 15M Key Zones'), reason: source);
      }
    });

    test('with a 1H level and a 15M level both touched, the 15M one is the trade', () async {
      final r = await evaluate(const [
        HtfZone(price: 2400, source: '1H Support'),
        HtfZone(price: 2399.5, source: '15M Support'),
      ]);
      expect(r.setup, isNotNull);
      expect(r.setup!.confluenceScore, 22 + 30 + 20 + 20);
    });

    test('a 1H/4H level still defines the range: it caps Take Profit as the far side', () async {
      // Entry 2404.2; the 15M support is the bounce. A 1H resistance at 2414 is the far side, 1.4R away,
      // and the full 1.8R target would land beyond it - so Take Profit is clipped to the 1H level.
      final r = await evaluate(const [
        HtfZone(price: 2400, source: '15M Support'),
        HtfZone(price: 2414, source: '1H Resistance'),
      ]);
      expect(r.setup, isNotNull);
      expect(r.setup!.takeProfit, 2414.0);
    });

    test('with only 1H/4H levels nothing is evaluated and the engine does not crash', () async {
      final engine = ZoneBounceEngine();
      final diagnosis = engine.diagnose(
        candles: _bounceMarket(),
        zones: const [HtfZone(price: 2400, source: '1H Support')],
        htfBias: null,
        candidateZones: const [],
      );
      expect(diagnosis.trigger, isNull);
      expect(diagnosis.reject, ZoneBounceReject.noZoneTouched);
    });

    test('with no candidate list the engine still considers every zone (its own default is unchanged)', () {
      final trigger = ZoneBounceEngine().findTrigger(
        candles: _bounceMarket(),
        zones: const [HtfZone(price: 2400, source: '1H Support')],
        htfBias: null,
      );
      expect(trigger, isNotNull);
    });
  });

  group('Range Bounce late-session no-entry window (OFF by default; 17:00-24:00 UTC when switched on)', () {
    const support = [HtfZone(price: 2400, source: '15M Support')];
    DateTime at(int hour, [int minute = 5]) => DateTime.utc(2026, 9, 25, hour, minute);

    void configure(Map<String, dynamic> params) => StrategyConfig.instance.setSnapshot(StrategyConfigSnapshot(5, {
          'engines': {
            'range_bounce': {'params': params}
          }
        }));

    test('it ships OFF: 24-24 by default, so a late-session bounce is taken', () async {
      expect((AppConfig.zoneBounceBlockStartUtc, AppConfig.zoneBounceBlockEndUtc), (24, 24));
      for (final hour in [17, 20, 23]) {
        expect(AppConfig.zoneBounceBlockedAt(at(hour)), isFalse, reason: 'hour $hour');
        expect((await evaluate(support, at: at(hour))).setup, isNotNull, reason: 'hour $hour');
      }
    });

    test('switched on with a start of 17, the window is 17:00 up to midnight', () {
      configure({'block_start_utc': 17});
      expect(AppConfig.zoneBounceBlockedAt(DateTime.utc(2026, 9, 25, 16, 59, 59)), isFalse);
      expect(AppConfig.zoneBounceBlockedAt(DateTime.utc(2026, 9, 25, 17, 0)), isTrue);
      expect(AppConfig.zoneBounceBlockedAt(DateTime.utc(2026, 9, 25, 23, 59, 59)), isTrue);
      expect(AppConfig.zoneBounceBlockedAt(DateTime.utc(2026, 9, 26, 0, 0)), isFalse);
    });

    test('switched on: a bounce is taken at 16:59 and 00:00 but not from 17:00 to 23:59', () async {
      configure({'block_start_utc': 17, 'block_end_utc': 24});
      expect((await evaluate(support, at: DateTime.utc(2026, 9, 25, 16, 59))).setup, isNotNull);
      expect((await evaluate(support, at: DateTime.utc(2026, 9, 26, 0, 0))).setup, isNotNull);
      for (final t in [at(17, 0), at(19), at(22, 30), DateTime.utc(2026, 9, 25, 23, 59)]) {
        final r = await evaluate(support, at: t);
        expect(r.setup, isNull, reason: '$t');
        expect(r.notes.join(' | '), allOf(contains('17:00-24:00 UTC'), contains('paused')), reason: '$t');
      }
    });

    test('switched on: the other hours of the day are all open', () async {
      configure({'block_start_utc': 17, 'block_end_utc': 24});
      for (final hour in [0, 3, 7, 10, 12, 14, 16]) {
        expect((await evaluate(support, at: at(hour))).setup, isNotNull, reason: 'hour $hour');
      }
    });

    test('a blocked scan consumes nothing: the same bounce fires once the window is over', () async {
      configure({'block_start_utc': 17, 'block_end_utc': 24});
      final checker = SignalChecker(clock: () => at(20));
      expect((await evaluate(support, checker: checker)).setup, isNull);
      final untouched = checker.debugCaptureState(EngineIds.rangeBounce);
      expect(untouched['candle'], isNull);
      expect((untouched['zones'] as Map).isEmpty, isTrue);
      final later = SignalChecker(clock: () => DateTime.utc(2026, 9, 26, 0, 10));
      expect((await evaluate(support, checker: later)).setup, isNotNull);
    });

    test('the bridge config moves the window', () async {
      configure({'block_start_utc': 20, 'block_end_utc': 22});
      expect((await evaluate(support, at: at(19, 59))).setup, isNotNull);
      expect((await evaluate(support, at: at(20, 0))).setup, isNull);
      expect((await evaluate(support, at: at(21, 59))).setup, isNull);
      expect((await evaluate(support, at: at(22, 0))).setup, isNotNull);
    });

    test('a start at or after the end switches the rule off', () async {
      configure({'block_start_utc': 24, 'block_end_utc': 24});
      expect((await evaluate(support, at: at(20))).setup, isNotNull);
      configure({'block_start_utc': 18, 'block_end_utc': 18});
      expect((await evaluate(support, at: at(18, 30))).setup, isNotNull);
    });

    test('the window only pauses Range Bounce: ICT is not affected by it', () async {
      final checker = SignalChecker(clock: () => at(20));
      final notes = <String>[];
      await checker.debugEvaluateIct(m15: _bounceMarket(), h1: const [], h4: const [], htfZones: const [], notes: notes, livePrice: 2404.2);
      expect(notes.join(' '), isNot(contains('late session')));
    });
  });

  group('Range Bounce hot-volatility gate (15M ATR > 1.2x its 3-day norm)', () {
    const support = [HtfZone(price: 2400, source: '15M Support')];
    final start = DateTime.utc(2026, 9, 22);

    /// [calm] quiet candles ($4 range) then [hot] candles of range [hotRange], all around 2406, then the usual
    /// pin-bar rejection off 2400.
    List<Candle> longMarket({int calm = 276, int hot = 23, double hotRange = 4}) => [
          for (var i = 0; i < calm + hot; i++)
            _c(start.add(Duration(minutes: 15 * i)), 2406, 2406 + (i < calm ? 4 : hotRange) / 2, 2406 - (i < calm ? 4 : hotRange) / 2, 2406),
          _c(start.add(Duration(minutes: 15 * (calm + hot))), 2403, 2404.5, 2398.5, 2404.2),
        ];

    void limit(double value) => StrategyConfig.instance.setSnapshot(StrategyConfigSnapshot(5, {
          'engines': {
            'range_bounce': {
              'params': {'max_atr_ratio': value}
            }
          }
        }));

    test('the limit defaults to 1.2', () {
      expect(AppConfig.zoneBounceMaxAtrRatio, 1.2);
    });

    test('a bounce in a calm market is taken', () async {
      expect((await evaluate(support, candles: longMarket())).setup, isNotNull);
    });

    test('the same bounce in a hot market is skipped, and the scan says how hot', () async {
      final r = await evaluate(support, candles: longMarket(hotRange: 12));
      expect(r.setup, isNull);
      expect(r.notes.join(' | '), allOf(contains('Hot volatility'), contains('limit 1.20×'), contains('3-day norm')));
    });

    test('a market only slightly hotter than normal (under 20%) is still fine', () async {
      expect((await evaluate(support, candles: longMarket(hotRange: 4.3))).setup, isNotNull);
    });

    test('the bridge config moves the limit, and a high limit switches the gate off', () async {
      limit(10);
      expect((await evaluate(support, candles: longMarket(hotRange: 12))).setup, isNotNull);
      limit(1.5);
      final mild = await evaluate(support, candles: longMarket(hotRange: 6));
      // ATR rises to about 1.4x its norm after 23 candles of range 6: under 1.5 passes, the default 1.2 would not
      expect(mild.setup, isNotNull);
      limit(1.0);
      expect((await evaluate(support, candles: longMarket(hotRange: 6))).setup, isNull);
    });

    test('with too little history the gate has no opinion and does not block', () async {
      expect((await evaluate(support, candles: longMarket(calm: 40, hot: 10, hotRange: 12))).setup, isNotNull);
    });

    test('a skipped bounce consumes nothing: it fires as soon as the market cools', () async {
      final checker = SignalChecker(clock: () => DateTime.utc(2026, 9, 25, 14, 5));
      expect((await evaluate(support, checker: checker, candles: longMarket(hotRange: 12))).setup, isNull);
      final untouched = checker.debugCaptureState(EngineIds.rangeBounce);
      expect(untouched['candle'], isNull);
      expect((untouched['zones'] as Map).isEmpty, isTrue);
      expect((await evaluate(support, checker: checker, candles: longMarket())).setup, isNotNull);
    });

    test('with no bounce at all the scan reports no bounce, not heat', () async {
      final noRejection = longMarket(hotRange: 12)..removeLast();
      noRejection.add(_c(start.add(const Duration(days: 4)), 2406, 2408, 2404, 2406));
      final r = await evaluate(support, candles: noRejection);
      expect(r.setup, isNull);
      expect(r.notes.join(' | '), allOf(contains('No clean rejection'), isNot(contains('Hot volatility'))));
    });
  });

  group('Range Bounce fresh-move gate (OFF by default; limit in ATR over 2 hours)', () {
    const support = [HtfZone(price: 2400, source: '15M Support')];
    const resistance = [HtfZone(price: 2420, source: '15M Resistance')];
    final start = DateTime.utc(2026, 9, 22);

    /// 280 calm candles around the top, then 8 candles falling [step] dollars each to ~2404, then the usual
    /// pin-bar rejection off 2400 - a BUY bounce that arrives after a fall of 8 x [step].
    List<Candle> fallMarket(double step) {
      final top = 2404 + step * 8;
      final out = <Candle>[
        for (var i = 0; i < 280; i++) _c(start.add(Duration(minutes: 15 * i)), top, top + 2, top - 2, top),
      ];
      var prev = top;
      for (var k = 1; k <= 8; k++) {
        final close = top - step * k;
        out.add(_c(start.add(Duration(minutes: 15 * (279 + k))), prev, prev + 0.5, close - 0.5, close));
        prev = close;
      }
      out.add(_c(start.add(const Duration(minutes: 15 * 288)), 2403, 2404.5, 2398.5, 2404.2));
      return out;
    }

    /// The same market seen from the other side: a SELL bounce off 2420 after a RALLY.
    List<Candle> rallyMarket(double step) => [
          for (final c in fallMarket(step)) _c(c.time, 4820 - c.open, 4820 - c.low, 4820 - c.high, 4820 - c.close),
        ];

    void limit(double value) => StrategyConfig.instance.setSnapshot(StrategyConfigSnapshot(5, {
          'engines': {
            'range_bounce': {
              'params': {'max_fade_atr': value}
            }
          }
        }));

    test('it ships OFF: the default limit is 10 ATR and a sharp fall does not stop a bounce', () async {
      expect(AppConfig.zoneBounceMaxFadeAtr, 10.0);
      expect((await evaluate(support, candles: fallMarket(2.5))).setup?.direction, TradeDirection.buy);
      expect((await evaluate(resistance, candles: rallyMarket(2.5), livePrice: 2415.8)).setup?.direction, TradeDirection.sell);
    });

    test('switched on (3 ATR), a BUY bounce right after a sharp fall is skipped, and the scan says how sharp', () async {
      limit(3);
      final r = await evaluate(support, candles: fallMarket(2.5));
      expect(r.setup, isNull);
      expect(r.notes.join(' | '), allOf(contains('Fading a sharp move'), contains('down'), contains('BUY bounce skipped')));
    });

    test('switched on (3 ATR), a SELL bounce right after a sharp rally is skipped too', () async {
      limit(3);
      final r = await evaluate(resistance, candles: rallyMarket(2.5), livePrice: 2415.8);
      expect(r.setup, isNull);
      expect(r.notes.join(' | '), allOf(contains('Fading a sharp move'), contains('up'), contains('SELL bounce skipped')));
    });

    test('switched on (3 ATR), the same bounces after a mild move are taken', () async {
      limit(3);
      final buy = await evaluate(support, candles: fallMarket(0.5));
      expect(buy.setup?.direction, TradeDirection.buy);
      final sell = await evaluate(resistance, candles: rallyMarket(0.5), livePrice: 2415.8);
      expect(sell.setup?.direction, TradeDirection.sell);
    });

    test('the bridge config moves the limit, and a high limit switches the gate off', () async {
      limit(10);
      expect((await evaluate(support, candles: fallMarket(2.5))).setup, isNotNull);
      limit(5);
      expect((await evaluate(support, candles: fallMarket(2.5))).setup, isNotNull); // about 4.3 ATR, under 5
      limit(3);
      expect((await evaluate(support, candles: fallMarket(2.5))).setup, isNull);
    });

    test('a skipped bounce consumes nothing: it fires once the move has gone', () async {
      limit(3);
      final checker = SignalChecker(clock: () => DateTime.utc(2026, 9, 25, 14, 5));
      expect((await evaluate(support, checker: checker, candles: fallMarket(2.5))).setup, isNull);
      final untouched = checker.debugCaptureState(EngineIds.rangeBounce);
      expect(untouched['candle'], isNull);
      expect((untouched['zones'] as Map).isEmpty, isTrue);
      expect((await evaluate(support, checker: checker, candles: fallMarket(0.5))).setup, isNotNull);
    });

    test('with too little history the gate has no opinion', () async {
      expect((await evaluate(support)).setup, isNotNull); // the short 25-candle market
    });
  });
}
