import 'package:aureus_ai/models/candle.dart';
import 'package:aureus_ai/models/pivot.dart';
import 'package:aureus_ai/models/trade_setup.dart';
import 'package:aureus_ai/services/history_store.dart';
import 'package:aureus_ai/services/monitor_engine.dart';
import 'package:aureus_ai/services/signal_checker.dart';
import 'package:aureus_ai/services/tick_stream_service.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Candle _c(DateTime t, double o, double h, double l, double c) =>
    Candle(time: t, open: o, high: h, low: l, close: c, volume: 1);

TradeSetup _setup({
  TradeDirection dir = TradeDirection.buy,
  double entry = 2400,
  double sl = 2398,
  double tp = 2404,
  DateTime? at,
}) =>
    TradeSetup(
      symbol: 'XAUUSD',
      direction: dir,
      timeframeLabel: '15M',
      setupType: SetupType.htfReversal,
      entry: entry,
      stopLoss: sl,
      takeProfit: tp,
      pattern: CandlePattern.bullishEngulfing,
      detectedAt: at ?? DateTime.utc(2026, 9, 14, 10, 0, 20),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('closedCandlesOnly', () {
    test('drops the forming candle', () {
      final now = DateTime.utc(2026, 9, 14, 10, 7);
      final candles = [
        _c(DateTime.utc(2026, 9, 14, 9, 45), 1, 1, 1, 1),
        _c(DateTime.utc(2026, 9, 14, 10, 0), 1, 1, 1, 1), // closes 10:15 > now
      ];
      expect(closedCandlesOnly(candles, 15, now).length, 1);
    });
    test('keeps a candle that has just closed', () {
      final now = DateTime.utc(2026, 9, 14, 10, 15);
      final candles = [_c(DateTime.utc(2026, 9, 14, 10, 0), 1, 1, 1, 1)];
      expect(closedCandlesOnly(candles, 15, now).length, 1);
    });
  });

  group('evaluateOutcomeOverCandles', () {
    test('ignores wicks from before the trade existed', () {
      final s = _setup(at: DateTime.utc(2026, 9, 14, 10, 20));
      final candles = [
        _c(DateTime.utc(2026, 9, 14, 10, 0), 2400, 2405, 2397, 2400), // pre-entry: touches both
        _c(DateTime.utc(2026, 9, 14, 10, 15), 2400, 2401, 2399, 2400), // contains entry, >2m before
        _c(DateTime.utc(2026, 9, 14, 10, 30), 2400, 2401, 2399.5, 2400),
      ];
      expect(s.evaluateOutcomeOverCandles(candles), isNull);
    });
    test('finds the first touch across skipped candles, SL first on ties', () {
      final s = _setup(at: DateTime.utc(2026, 9, 14, 10, 0, 30));
      final candles = [
        _c(DateTime.utc(2026, 9, 14, 10, 0), 2400, 2401, 2399, 2400),
        _c(DateTime.utc(2026, 9, 14, 10, 15), 2400, 2404.5, 2399, 2404), // TP
        _c(DateTime.utc(2026, 9, 14, 10, 30), 2404, 2404, 2397, 2398), // SL later
      ];
      final r = s.evaluateOutcomeOverCandles(candles)!;
      expect(r.outcome, TradeOutcome.win);
      expect(r.exitPrice, 2404);
    });
  });

  group('evaluateOutcomeAtTick', () {
    test('SELL stops out on ASK, not BID', () {
      final s = _setup(dir: TradeDirection.sell, entry: 2400, sl: 2402, tp: 2396);
      expect(s.evaluateOutcomeAtTick(bid: 2401.8, ask: 2402.1)?.outcome, TradeOutcome.loss);
      expect(s.evaluateOutcomeAtTick(bid: 2395.9, ask: 2396.2), isNull); // ask still above TP
      expect(s.evaluateOutcomeAtTick(bid: 2395.7, ask: 2396.0)?.outcome, TradeOutcome.win);
    });
    test('BUY uses BID', () {
      final s = _setup();
      expect(s.evaluateOutcomeAtTick(bid: 2398.1, ask: 2397.9), isNull);
      expect(s.evaluateOutcomeAtTick(bid: 2398.0, ask: 2398.3)?.outcome, TradeOutcome.loss);
    });
  });

  test('duplicate detection and unique notification ids', () {
    final a = _setup();
    final b = _setup(at: a.detectedAt.add(const Duration(minutes: 5)));
    final c = _setup(entry: 2401);
    expect(b.isDuplicateOf(a), isTrue);
    expect(c.isDuplicateOf(a), isFalse);
    expect(a.notificationId(), isNot(a.notificationId(salt: 1)));
    expect(a.notificationId(), greaterThanOrEqualTo(0));
  });

  test('Tick.fromJson prefers millisecond time and reads ask', () {
    final t = Tick.fromJson({'time': 1757844000, 'time_msc': 1757844000123, 'bid': 2400.1, 'ask': 2400.4, 'last': 0});
    expect(t.time.millisecond, 123);
    expect(t.ask, 2400.4);
  });

  test('HistoryStore round-trips and skips corrupt entries', () async {
    SharedPreferences.setMockInitialValues({
      TradeSetup.historyPrefsKey: ['{not json'],
    });
    await HistoryStore.mutate((h) {
      h.add(_setup());
      return true;
    });
    final loaded = await HistoryStore.load();
    expect(loaded.length, 1);
    expect(loaded.first.entry, 2400);
  });

  test('full mock monitoring cycles complete without errors', () async {
    SharedPreferences.setMockInitialValues({});
    dotenv.testLoad(fileInput: 'USE_MOCK_DATA=true');
    final events = <Map<String, Object?>>[];
    final engine = MonitorEngine(onEvent: events.add);
    await engine.init();
    for (var i = 0; i < 3; i++) {
      await engine.runCycle();
    }
    final cycles = events.where((e) => e['type'] == 'cycle').toList();
    expect(cycles.length, 3);
    for (final e in cycles) {
      expect(e['ok'], isTrue, reason: '${e['status']}');
    }
    // Re-running on the same closed candles must not add duplicates.
    final history = await HistoryStore.load();
    final uids = history.map((s) => '${s.setupType}|${s.direction}|${s.entry}').toList();
    expect(uids.toSet().length, uids.length);
  });
}
