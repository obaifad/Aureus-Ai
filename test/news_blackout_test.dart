import 'dart:convert';

import 'package:aureus_ai/config/app_config.dart';
import 'package:aureus_ai/models/candle.dart';
import 'package:aureus_ai/services/app_logger.dart';
import 'package:aureus_ai/services/data_service.dart';
import 'package:aureus_ai/services/signal_checker.dart';
import 'package:aureus_ai/services/strategy_config_service.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The high-impact news blackout for EVERY engine (2026-10-09): no new entry within
/// `filters.news.blackout_minutes` of a high-impact USD release, either side of it.

Candle _c(DateTime t, double o, double h, double l, double c) => Candle(time: t, open: o, high: h, low: l, close: c, volume: 1);

class _FakeData implements DataService {
  _FakeData({required this.m15, required this.h1, required this.h4});
  final List<Candle> m15, h1, h4;

  @override
  Future<List<Candle>> getCandles({required int timeframeMinutes, int count = 300, String? symbol}) async {
    final source = switch (timeframeMinutes) {
      15 => m15,
      60 => h1,
      240 => h4,
      _ => const <Candle>[],
    };
    return source.length <= count ? source : source.sublist(source.length - count);
  }
}

/// ForexFactory-style calendar rows (times in New York, as the real feed has them).
Map<String, Object> _event(String title, String date, {String country = 'USD', String impact = 'High'}) =>
    {'title': title, 'country': country, 'impact': impact, 'date': date};

void _seedCalendar(List<Map<String, Object>> events) {
  SharedPreferences.setMockInitialValues({
    'aureus_news_cache_v1': jsonEncode(events),
    'aureus_news_cache_time_v1': DateTime.now().millisecondsSinceEpoch,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Scan clock 10:07 UTC; a release "at 10:15 UTC" is 06:15 New York time (EDT, -04:00).
  final now = DateTime.utc(2026, 9, 22, 10, 7);
  List<Candle> flat(int tfMinutes, int count) => [
        for (var i = 0; i < count; i++)
          _c(DateTime.utc(2026, 9, 22, 10).subtract(Duration(minutes: tfMinutes * (count - i))), 2400, 2402, 2398, 2400),
      ];

  Future<SignalCheckResult> scan({Map<String, dynamic>? news, SignalChecker? checker}) async {
    dotenv.testLoad(fileInput: 'USE_MOCK_DATA=false\nDISABLE_MT5_BRIDGE=true');
    StrategyConfig.instance.setSnapshot(StrategyConfigSnapshot(5, {
      'filters': {
        'chaos': {'mode': 'off'},
        if (news != null) 'news': news,
      },
    }));
    final data = _FakeData(m15: flat(15, 200), h1: flat(60, 80), h4: flat(240, 80));
    return (checker ?? SignalChecker(clock: () => now, dataServiceFactory: () => data)).check();
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    StrategyConfig.instance.resetForTesting();
  });
  tearDown(() => StrategyConfig.instance.resetForTesting());

  test('defaults: on, 15 minutes either side — the same as the bridge switch', () {
    dotenv.testLoad(fileInput: '');
    expect(AppConfig.newsFilterEnabled, isTrue);
    expect(AppConfig.newsBlackoutMinutes, 15);
    StrategyConfig.instance.setSnapshot(const StrategyConfigSnapshot(5, {
      'filters': {
        'news': {'enabled': false, 'blackout_minutes': 30}
      }
    }));
    expect(AppConfig.newsFilterEnabled, isFalse);
    expect(AppConfig.newsBlackoutMinutes, 30);
  });

  test('a high-impact USD release 8 minutes away pauses every engine, and says which release', () async {
    _seedCalendar([_event('CPI m/m', '2026-09-22T06:15:00-04:00')]);
    final result = await scan(news: {'enabled': true, 'blackout_minutes': 15});
    expect(result.setups, isEmpty);
    expect(result.status, allOf(contains('News blackout'), contains('CPI m/m'), contains('10:15 UTC')));
    expect(result.status, isNot(contains('Key Zones')), reason: 'the scan stopped before any engine work');
    expect(AppLogger.entries.where((l) => l.contains('📰 News blackout') && l.contains('CPI m/m')), isNotEmpty);
  });

  test('the minutes AFTER a release are blocked too', () async {
    _seedCalendar([_event('Non-Farm Employment Change', '2026-09-22T05:55:00-04:00')]); // 09:55 UTC, 12 min ago
    final result = await scan(news: {'enabled': true, 'blackout_minutes': 15});
    expect(result.status, contains('News blackout'));
  });

  test('outside the window the engines run as usual', () async {
    _seedCalendar([_event('CPI m/m', '2026-09-22T06:30:00-04:00')]); // 10:30 UTC, 23 min away
    final result = await scan(news: {'enabled': true, 'blackout_minutes': 15});
    expect(result.status, isNot(contains('News blackout')));
    expect(result.status, contains('No HTF Key Zones'), reason: 'the scan went on to the engines');
  });

  test('the window width comes from the bridge config', () async {
    _seedCalendar([_event('CPI m/m', '2026-09-22T06:30:00-04:00')]); // 23 min away
    final result = await scan(news: {'enabled': true, 'blackout_minutes': 30});
    expect(result.status, contains('News blackout'));
  });

  test('only high-impact USD counts: medium USD and high EUR at the same minute do not block', () async {
    _seedCalendar([
      _event('Richmond Manufacturing Index', '2026-09-22T06:10:00-04:00', impact: 'Medium'),
      _event('ECB President Speaks', '2026-09-22T06:10:00-04:00', country: 'EUR'),
    ]);
    final result = await scan(news: {'enabled': true, 'blackout_minutes': 15});
    expect(result.status, isNot(contains('News blackout')));
  });

  test('switched off in the control screen (or 0 minutes) it never blocks', () async {
    _seedCalendar([_event('CPI m/m', '2026-09-22T06:10:00-04:00')]);
    expect((await scan(news: {'enabled': false, 'blackout_minutes': 15})).status, isNot(contains('News blackout')));
    expect((await scan(news: {'enabled': true, 'blackout_minutes': 0})).status, isNot(contains('News blackout')));
  });

  test('one log line per release, however many scans fall inside its window', () async {
    _seedCalendar([_event('FOMC Statement', '2026-09-22T06:15:00-04:00')]);
    final data = _FakeData(m15: flat(15, 200), h1: flat(60, 80), h4: flat(240, 80));
    final checker = SignalChecker(clock: () => now, dataServiceFactory: () => data);
    final before = AppLogger.entries.length;
    await scan(news: {'enabled': true, 'blackout_minutes': 15}, checker: checker);
    await scan(news: {'enabled': true, 'blackout_minutes': 15}, checker: checker);
    expect(AppLogger.entries.skip(before).where((l) => l.contains('📰 News blackout')).length, 1);
  });

  test('no calendar (feed down, nothing cached) never blocks', () async {
    final result = await scan(news: {'enabled': true, 'blackout_minutes': 15});
    expect(result.status, isNot(contains('News blackout')));
  });
}
