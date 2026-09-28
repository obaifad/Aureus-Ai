// ignore_for_file: avoid_print
// Full-portfolio backtest: replays the REAL SignalChecker.check() pipeline
// (every engine, every gate, engine priority, One Active Trade Limit, outcome
// sweep) over historical candles fetched from MT5 through the bridge.
//
//   BT_HOURS=120 flutter test test/_backtest_all.dart
//
// How it stays faithful: SignalChecker takes an injectable clock and data
// source. At each 5-minute step (5s after a candle boundary, like a live scan
// just after a close) the clock is set to that instant and the data service
// serves ONLY what the market would have shown then — closed candles plus a
// partially-built forming candle aggregated from the closed 5M candles so far
// — sliced to the same window sizes the app requests (4H:150, 1H:300,
// 15M:300, 5M:200). Trades are persisted through HistoryStore exactly like
// MonitorEngine does, so the One Active Trade Limit and outcome sweep work on
// simulated state.
//
// NOT modelled (no historical feed): DXY filter (disabled; the live filter
// covers HTF Retest/ICT/ICI/ORB/Breakout but NOT Range Bounce, which is exempt), High-Impact news blackout (disabled), live
// spread protection, tick-level SL/TP (outcomes resolve on 5-minute steps
// over 15M candles, SL-before-TP inside a step).
import 'dart:convert';
import 'dart:io';

import 'package:aureus_ai/config/app_config.dart';
import 'package:aureus_ai/models/candle.dart';
import 'package:aureus_ai/models/pivot.dart';
import 'package:aureus_ai/models/trade_setup.dart';
import 'package:aureus_ai/services/data_service.dart';
import 'package:aureus_ai/services/history_store.dart';
import 'package:aureus_ai/services/signal_checker.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _secretHints = ['KEY', 'TOKEN', 'SECRET', 'CHAT', 'PASSWORD'];

/// The app's real .env with every secret dropped (so a replayed trade can
/// never reach Telegram / a broker) and the network-bound filters disabled.
String buildEnv(String bridgeKeyOut) {
  final kept = <String>[];
  for (final raw in File('.env').readAsLinesSync()) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#') || !line.contains('=')) continue;
    final key = line.substring(0, line.indexOf('=')).trim();
    if (key == 'BRIDGE_API_KEY') {
      bridgeKeyOut = line.substring(line.indexOf('=') + 1).trim();
      continue;
    }
    if (_secretHints.any(key.toUpperCase().contains)) continue;
    kept.add(line);
  }
  const overrides = {
    'USE_DXY_FILTER': 'false',
    'BREAKOUT_NEWS_FILTER': 'false',
    'DISABLE_MT5_BRIDGE': 'true',
    'ENABLE_AUTO_TRADING': 'false',
  };
  // BT_ENV="KEY=v,KEY2=v2" applies extra overrides for what-if runs.
  final extra = <String, String>{
    for (final kv in (Platform.environment['BT_ENV'] ?? '').split(',').where((e) => e.contains('=')))
      kv.split('=')[0].trim(): kv.split('=')[1].trim(),
  };
  final all = {...overrides, ...extra};
  kept.removeWhere((l) => all.containsKey(l.substring(0, l.indexOf('=')).trim()));
  kept.addAll(all.entries.map((e) => '${e.key}=${e.value}'));
  return kept.join('\n');
}

String bridgeKey() {
  for (final raw in File('.env').readAsLinesSync()) {
    final line = raw.trim();
    if (line.startsWith('BRIDGE_API_KEY=')) return line.substring('BRIDGE_API_KEY='.length).trim();
  }
  return '';
}

Future<List<Candle>> fetch(String key, int tf, int count) async {
  final uri = Uri.parse('http://127.0.0.1:8000/candles?symbol=XAUUSD...&timeframe=$tf&count=$count');
  final req = await HttpClient().getUrl(uri);
  req.headers.set('X-API-Key', key);
  final res = await req.close();
  final body = await res.transform(utf8.decoder).join();
  final list = jsonDecode(body) as List;
  return [
    for (final c in list)
      Candle(
        time: DateTime.fromMillisecondsSinceEpoch((c['time'] as num).toInt() * 1000, isUtc: true),
        open: (c['open'] as num).toDouble(),
        high: (c['high'] as num).toDouble(),
        low: (c['low'] as num).toDouble(),
        close: (c['close'] as num).toDouble(),
        volume: (c['tick_volume'] as num?)?.toDouble() ?? 0,
      ),
  ];
}

DateTime floorTo(DateTime t, Duration d) =>
    DateTime.fromMillisecondsSinceEpoch(t.millisecondsSinceEpoch - t.millisecondsSinceEpoch % d.inMilliseconds, isUtc: true);

/// Serves the market as it looked at [now]().
class ReplayDataService implements DataService {
  final DateTime Function() now;
  final Map<int, List<Candle>> byTf;
  final List<Candle> m5;

  ReplayDataService(this.now, this.byTf, this.m5);

  @override
  Future<List<Candle>> getCandles({required int timeframeMinutes, int count = 300, String? symbol}) async {
    final t = now();
    final tf = Duration(minutes: timeframeMinutes);
    final src = byTf[timeframeMinutes]!;
    final out = src.where((c) => !c.time.add(tf).isAfter(t)).toList();

    // Forming candle: aggregate the 5M candles already closed inside it.
    final start = floorTo(t, tf);
    final parts = m5.where((c) => !c.time.isBefore(start) && !c.time.add(const Duration(minutes: 5)).isAfter(t)).toList();
    if (parts.isNotEmpty) {
      out.add(Candle(
        time: start,
        open: parts.first.open,
        high: parts.map((c) => c.high).reduce((a, b) => a > b ? a : b),
        low: parts.map((c) => c.low).reduce((a, b) => a < b ? a : b),
        close: parts.last.close,
        volume: parts.fold<double>(0, (a, c) => a + c.volume),
      ));
    } else {
      final real = src.where((c) => c.time == start);
      if (real.isNotEmpty) {
        final o = real.first.open;
        out.add(Candle(time: start, open: o, high: o, low: o, close: o, volume: 0));
      }
    }
    return out.length <= count ? out : out.sublist(out.length - count);
  }
}

String hhmm(DateTime t) => '${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

void main() {
  test('full portfolio backtest', () async {
    final hours = int.tryParse(Platform.environment['BT_HOURS'] ?? '') ?? 120;

    var unusedKey = '';
    dotenv.testLoad(fileInput: buildEnv(unusedKey));
    SharedPreferences.setMockInitialValues({});
    final key = bridgeKey();

    // History needed: 300 x 15M / 300 x 1H / 150 x 4H before the first step.
    final m5All = await fetch(key, 5, 1900);
    final m15All = await fetch(key, 15, 900);
    final h1All = await fetch(key, 60, 600);
    final h4All = await fetch(key, 240, 300);
    final byTf = {5: m5All, 15: m15All, 60: h1All, 240: h4All};

    final lastClosed5 = m5All.where((c) => !c.time.add(const Duration(minutes: 5)).isAfter(DateTime.now().toUtc())).last;
    final end = lastClosed5.time.add(const Duration(minutes: 5)); // boundary after the last closed 5M
    final first = end.subtract(Duration(hours: hours));
    final need5 = first.subtract(const Duration(minutes: 5 * 200));
    if (m5All.first.time.isAfter(need5)) {
      print('تنبيه: بيانات 5M تبدأ ${hhmm(m5All.first.time)} بعد ما يحتاجه أول خطوة ${hhmm(need5)}');
    }

    var simNow = first;
    final checker = SignalChecker(
      dataServiceFactory: () => ReplayDataService(() => simNow, byTf, m5All),
      clock: () => simNow,
    );

    print('\n${'=' * 70}');
    print('الباكتست الشامل: ${hhmm(first)} → ${hhmm(end)} UTC  ($hours ساعة)');
    print('إعدادات: ORB=${AppConfig.useOrb} Breakout=${AppConfig.useBreakoutMomentum} '
        'RangeBounce=${AppConfig.enableRangingBounceMode}  R:R=1:${AppConfig.riskRewardRatio}  '
        'BreakoutTP=${AppConfig.breakoutTakeProfitRMultiple}R  BreakEven=${AppConfig.breakEvenEnabled}');
    print('=' * 70);

    final sw = Stopwatch()..start();
    var steps = 0, errors = 0, signalCycles = 0;
    for (var t = first; t.isBefore(end); t = t.add(const Duration(minutes: 5))) {
      simNow = t.add(const Duration(seconds: 5));
      try {
        final result = await checker.check();
        if (steps < 2 || steps % 100 == 0) {
          print('  [status @${hhmm(t)}] ${result.status.length > 260 ? result.status.substring(0, 260) : result.status}');
        }
        if (result.setups.isNotEmpty) {
          signalCycles++;
          await HistoryStore.mutate((history) {
            final added = result.setups.where((s) => !history.any((h) => h.isDuplicateOf(s))).toList();
            history.insertAll(0, added);
            return added.isNotEmpty;
          });
        }
      } catch (e) {
        errors++;
        if (errors <= 3) print('  [خطأ عند ${hhmm(t)}] $e');
      }
      steps++;
      if (steps % 200 == 0) {
        print('  ... $steps خطوة (${hhmm(t)})  ${sw.elapsed.inSeconds}s');
      }
    }
    print('  اكتملت $steps خطوة في ${sw.elapsed.inSeconds}s، أخطاء: $errors، دورات فيها إشارة: $signalCycles');

    // ------------------------------- report -------------------------------
    final history = (await HistoryStore.load()).reversed.toList();
    final lastPrice = m5All.last.close;

    double pipsOf(TradeSetup s) {
      if (s.outcome == TradeOutcome.open) {
        final d = s.direction == TradeDirection.buy ? lastPrice - s.entry : s.entry - lastPrice;
        return d / TradeSetup.dollarsPerPip;
      }
      return s.pips ?? 0;
    }

    print('\n[1] تفصيل كل استراتيجية');
    final families = [
      (StrategyFamily.topDown, 'HTF Retest (Top-Down)'),
      (StrategyFamily.rangingBounce, 'Range Bounce'),
      (StrategyFamily.orb, 'ORB'),
      (StrategyFamily.ict, 'ICT'),
      (StrategyFamily.breakout, 'Breakout / Momentum'),
      (StrategyFamily.ici, 'ICI'),
    ];
    var totalWins = 0, totalLosses = 0;
    var grossWin = 0.0, grossLoss = 0.0, netClosed = 0.0, netOpen = 0.0;
    var totalOpen = 0;
    for (final (fam, label) in families) {
      final ts = history.where((s) => s.setupType.strategyFamily == fam).toList();
      final w = ts.where((s) => s.outcome == TradeOutcome.win).toList();
      final l = ts.where((s) => s.outcome == TradeOutcome.loss).toList();
      final o = ts.where((s) => s.outcome == TradeOutcome.open).toList();
      final closed = w.length + l.length;
      final net = [...w, ...l].fold<double>(0, (a, s) => a + pipsOf(s));
      final floating = o.fold<double>(0, (a, s) => a + pipsOf(s));
      totalWins += w.length;
      totalLosses += l.length;
      totalOpen += o.length;
      netClosed += net;
      netOpen += floating;
      grossWin += w.fold<double>(0, (a, s) => a + pipsOf(s));
      grossLoss += l.fold<double>(0, (a, s) => a + pipsOf(s)).abs();
      print('  ${label.padRight(24)} صفقات ${ts.length.toString().padLeft(2)} | '
          'رابحة ${w.length} | خاسرة ${l.length} | مفتوحة ${o.length} | '
          'فوز ${closed == 0 ? "—" : "${(w.length / closed * 100).toStringAsFixed(0)}%"} | '
          'صافي ${net >= 0 ? "+" : ""}${net.toStringAsFixed(1)}p'
          '${o.isEmpty ? "" : "  (عائم ${floating >= 0 ? "+" : ""}${floating.toStringAsFixed(1)}p)"}');
    }

    print('\n[2] المحفظة مجتمعة');
    final closedTotal = totalWins + totalLosses;
    print('  إجمالي الصفقات المنفَّذة: ${history.length}  (مغلقة $closedTotal، مفتوحة $totalOpen)');
    print('  نسبة الفوز: ${closedTotal == 0 ? "غير متاحة" : "${(totalWins / closedTotal * 100).toStringAsFixed(1)}%"}  '
        '($totalWins رابحة / $totalLosses خاسرة)');
    print('  صافي المغلقة: ${netClosed >= 0 ? "+" : ""}${netClosed.toStringAsFixed(1)} pips');
    if (totalOpen > 0) {
      print('  عائم على المفتوحة: ${netOpen >= 0 ? "+" : ""}${netOpen.toStringAsFixed(1)} pips');
    }
    print('  معامل الربح: ${grossLoss == 0 ? "غير متاح" : (grossWin / grossLoss).toStringAsFixed(2)}');

    // ---- overlap: trades that fired while another one was still open ----
    DateTime endOf(TradeSetup s) => s.closedAt?.toUtc() ?? DateTime.utc(2100);
    final overlapped = <TradeSetup, List<TradeSetup>>{};
    var maxConcurrent = 0;
    for (final s in history) {
      final t = s.detectedAt.toUtc();
      final holders = history
          .where((o) => !identical(o, s) && o.detectedAt.toUtc().isBefore(t) && endOf(o).isAfter(t))
          .toList();
      if (holders.isNotEmpty) overlapped[s] = holders;
      final concurrent = history.where((o) => !o.detectedAt.toUtc().isAfter(t) && endOf(o).isAfter(t)).length;
      if (concurrent > maxConcurrent) maxConcurrent = concurrent;
    }
    print('\n[2b] التزامن: ${overlapped.length} صفقة فُتحت أثناء صفقة أخرى مفتوحة | '
        'أقصى صفقات مفتوحة معاً: $maxConcurrent');
    if (overlapped.isNotEmpty) {
      final ow = overlapped.keys.where((s) => s.outcome == TradeOutcome.win).length;
      final ol = overlapped.keys.where((s) => s.outcome == TradeOutcome.loss).length;
      final onet = overlapped.keys.fold<double>(0, (a, s) => a + pipsOf(s));
      print('     المتزامنة: $ow رابحة / $ol خاسرة  صافي ${onet >= 0 ? "+" : ""}${onet.toStringAsFixed(1)}p');
    }

    print('\n[3] كل الصفقات بالترتيب الزمني');
    for (final s in history) {
      final p = pipsOf(s);
      print('  ${hhmm(s.detectedAt.toUtc())}  ${s.directionLabel.padRight(4)} ${s.setupType.strategyFamily.label.padRight(11)} '
          '${s.setupType.label.padRight(34)} دخول ${s.entry.toStringAsFixed(2)} '
          'R:R 1:${s.riskRewardRatio.toStringAsFixed(2)} SL ${(s.riskDollars / TradeSetup.dollarsPerPip).toStringAsFixed(0)}p '
          '⟵ ${s.outcome.name.padRight(4)} ${p >= 0 ? "+" : ""}${p.toStringAsFixed(1)}p'
          '${s.closedAt != null ? "  @${hhmm(s.closedAt!.toUtc())}" : ""}'
          '${overlapped.containsKey(s) ? "   ⚠ أثناء: ${overlapped[s]!.map((h) => h.setupType.strategyFamily.label).join("+")}" : ""}');
    }
    print('${'=' * 70}\n');
  }, timeout: const Timeout(Duration(minutes: 90)));
}
