// ignore_for_file: avoid_print
// Backtest of the Ranging Market Module (ZoneBounceEngine) over the last N
// hours of live bridge data (default 72h, override with BT_HOURS).
//   flutter test test/_backtest_range.dart
//
// Point-in-time replay: at every CLOSED 15M candle the zones and the HTF
// bias are rebuilt from ONLY the candles that had closed by then — no
// lookahead, and the still-forming candle is never used. Rejection reasons
// come from ZoneBounceEngine.diagnose (the same gates that decide), not a
// reconstruction. Signals then pass the gates SignalChecker applies after
// the engine (R:R floor, min/max SL, min TP, score floor, one active trade,
// zone cooldown). DXY / news / stale-drift are NOT modelled (no historical
// feed). Outcome: SL checked before TP inside a candle (conservative); the
// Stop Loss never moves (Break-Even is disabled in the live config).
import 'dart:convert';
import 'dart:io';

import 'package:aureus_ai/config/app_config.dart';
import 'package:aureus_ai/models/candle.dart';
import 'package:aureus_ai/models/pivot.dart';
import 'package:aureus_ai/models/trade_setup.dart';
import 'package:aureus_ai/services/ict_engine.dart';
import 'package:aureus_ai/services/ta_engine.dart';
import 'package:aureus_ai/services/zone_bounce_engine.dart';
import 'package:flutter_test/flutter_test.dart';

const _key = 'kYiaZ8O4SlQ2yX7J3hM0tczRfujIxDETno';

Future<List<Candle>> fetch(int tf, int count) async {
  final uri = Uri.parse('http://127.0.0.1:8000/candles?symbol=XAUUSD...&timeframe=$tf&count=$count');
  final req = await HttpClient().getUrl(uri);
  req.headers.set('X-API-Key', _key);
  final res = await req.close();
  final list = jsonDecode(await res.transform(utf8.decoder).join()) as List;
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

/// Candles whose close time is not after [asOf].
List<Candle> closedBy(List<Candle> all, Duration tf, DateTime asOf) =>
    all.where((c) => !c.time.add(tf).isAfter(asOf)).toList();

String hhmm(DateTime t) => '${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// Mirror of SignalChecker._zoneBounceConfluenceScore (private there).
int score(TradeSetup s, ZoneBounceTrigger t) {
  var sc = switch (t.pattern) {
    CandlePattern.bullishEngulfing || CandlePattern.bearishEngulfing => 30,
    CandlePattern.bullishPinbar || CandlePattern.bearishPinbar => 22,
    _ => 15,
  };
  sc += t.zone.source.startsWith('4H') ? 30 : t.zone.source.startsWith('1H') ? 22 : 10;
  final pen = (t.isBuy ? t.zone.price - t.rejectionExtreme : t.rejectionExtreme - t.zone.price)
      .clamp(0.0, double.infinity);
  sc += (pen / AppConfig.zoneBounceTouchDollars * 20).clamp(0.0, 20.0).round();
  sc += ((s.riskRewardRatio / AppConfig.riskRewardRatio).clamp(0.0, 1.0) * 20).round();
  return sc.clamp(0, 100);
}

void main() {
  test('range bounce backtest', () async {
    final hours = int.tryParse(Platform.environment['BT_HOURS'] ?? '') ?? 72;
    final m15All = await fetch(15, 1200);
    final h1All = await fetch(60, 299);
    final h4All = await fetch(240, 149);

    final ta = TaEngine();
    final ict = IctEngine();
    final engine = ZoneBounceEngine();

    // Real wall-clock: the still-forming candle is never part of the replay.
    final closed15 = closedBy(m15All, const Duration(minutes: 15), DateTime.now().toUtc());
    final endTime = closed15.last.time;
    final startTime = endTime.subtract(Duration(hours: hours)).add(const Duration(minutes: 15));
    final replay = closed15.where((c) => !c.time.isBefore(startTime)).toList();
    final history = m15All.indexWhere((c) => c.time == replay.first.time);

    print('\n${'=' * 68}');
    print('نافذة الاختبار: ${hhmm(replay.first.time)} → ${hhmm(replay.last.time)} UTC  '
        '(${replay.length} شمعة 15M مغلقة، $history شمعة تاريخ قبلها للمناطق)');
    print('السعر: ${replay.first.open} → ${replay.last.close}   '
        'المدى: ${replay.map((c) => c.low).reduce((a, b) => a < b ? a : b)}'
        ' – ${replay.map((c) => c.high).reduce((a, b) => a > b ? a : b)}');
    print('=' * 68);

    final noTrigger = <ZoneBounceReject, int>{};
    final rejectedSetups = <Map<String, String>>[];
    final rejectedByReason = <String, int>{};
    final trades = <Map<String, dynamic>>[];
    DateTime? openUntil;
    final zoneCooldown = <String, DateTime>{};
    var engineFired = 0;

    void rejectSetup(DateTime t, ZoneBounceTrigger trig, String reason) {
      rejectedByReason[reason] = (rejectedByReason[reason] ?? 0) + 1;
      rejectedSetups.add({
        'time': hhmm(t),
        'what': '${trig.direction.name.toUpperCase()} ${trig.zone.source} '
            '\$${trig.zone.price.toStringAsFixed(2)} ${trig.pattern.shapeLabel}',
        'why': reason,
      });
    }

    for (final candle in replay) {
      final idx = m15All.indexWhere((c) => c.time == candle.time);
      final asOf = candle.time.add(const Duration(minutes: 15));
      final m15 = m15All.sublist(0, idx + 1);
      final h1 = closedBy(h1All, const Duration(hours: 1), asOf);
      final h4 = closedBy(h4All, const Duration(hours: 4), asOf);

      final b4 = ict.structureBias(h4);
      final b1 = ict.structureBias(h1);
      final bias = (b4 != null && b4 == b1) ? b4 : null;
      final zones = ta.buildHtfZones(candles15m: m15, candles1h: h1, candles4h: h4);

      final d = engine.diagnose(candles: m15, zones: zones, htfBias: bias);
      if (Platform.environment['BT_PROBE'] == hhmm(candle.time)) {
        final prev = m15[m15.length - 2];
        print('  [PROBE ${hhmm(candle.time)}] O ${candle.open} H ${candle.high} L ${candle.low} C ${candle.close} | prev close ${prev.close}');
        for (final z in ta.findNearestZones(zones, candle.close, count: 3)) {
          print('     zone ${z.source} ${z.price.toStringAsFixed(2)}');
        }
        print('     => ${d.trigger != null ? "FIRED" : d.reject!.label}');
      }
      if (d.trigger == null) {
        noTrigger[d.reject!] = (noTrigger[d.reject!] ?? 0) + 1;
        continue;
      }
      final trig = d.trigger!;
      engineFired++;

      // ---- SignalChecker gates that run after the engine ----
      final entry = trig.rejectionCandle.close;
      final atr = ta.averageTrueRange(m15, period: 14);
      final sl = engine.stopLossFor(trig, atr: atr);
      if (sl == null) {
        rejectSetup(candle.time, trig, 'مسافة مخاطرة غير صالحة');
        continue;
      }
      final tp = engine.takeProfitFor(trig, entry: entry, stopLoss: sl);
      final fixedTp = trig.isBuy
          ? entry + AppConfig.riskRewardRatio * (entry - sl).abs()
          : entry - AppConfig.riskRewardRatio * (entry - sl).abs();
      final clipped = (tp - fixedTp).abs() > 0.005;
      final setup = TradeSetup(
        symbol: 'XAUUSD',
        direction: trig.direction,
        timeframeLabel: '15M',
        setupType: SetupType.rangingBounce,
        entry: entry,
        stopLoss: sl,
        takeProfit: tp,
        pattern: trig.pattern,
        detectedAt: asOf,
      );
      final slPips = (entry - sl).abs() / TradeSetup.dollarsPerPip;
      final tpPips = (tp - entry).abs() / TradeSetup.dollarsPerPip;
      final rr = setup.riskRewardRatio;

      if (rr < AppConfig.zoneBounceMinRiskReward) {
        rejectSetup(candle.time, trig,
            'R:R ${rr.toStringAsFixed(2)} < ${AppConfig.zoneBounceMinRiskReward} '
            '(حد النطاق على ${((trig.rangeBoundary! - entry).abs() / (entry - sl).abs()).toStringAsFixed(2)}R قصّ الهدف)');
        continue;
      }
      if (tpPips < AppConfig.minTakeProfitPips) {
        rejectSetup(candle.time, trig,
            'مسافة الهدف ${tpPips.toStringAsFixed(0)}p < ${AppConfig.minTakeProfitPips.toStringAsFixed(0)}p');
        continue;
      }
      if (slPips < AppConfig.minStopLossPips) {
        rejectSetup(candle.time, trig,
            'مسافة الستوب ${slPips.toStringAsFixed(0)}p < ${AppConfig.minStopLossPips.toStringAsFixed(0)}p');
        continue;
      }
      if (slPips > AppConfig.maxStopLossPips) {
        rejectSetup(candle.time, trig,
            'مسافة الستوب ${slPips.toStringAsFixed(0)}p > ${AppConfig.maxStopLossPips.toStringAsFixed(0)}p');
        continue;
      }
      final sc = score(setup, trig);
      if (sc < AppConfig.minConfluenceScoreZoneBounce) {
        rejectSetup(candle.time, trig, 'درجة الثقة $sc < ${AppConfig.minConfluenceScoreZoneBounce}');
        continue;
      }
      if (openUntil != null && asOf.isBefore(openUntil)) {
        rejectSetup(candle.time, trig, 'صفقة أخرى نشطة (حد صفقة واحدة)');
        continue;
      }
      final zk = trig.zone.price.toStringAsFixed(2);
      final lastFire = zoneCooldown[zk];
      if (lastFire != null && asOf.difference(lastFire) < AppConfig.directionalDebounceWindow) {
        rejectSetup(candle.time, trig, 'المنطقة ضمن فترة التبريد');
        continue;
      }

      // ---- Simulate the outcome on the candles AFTER the entry candle ----
      var outcome = 'مفتوحة';
      var exit = closed15.last.close;
      DateTime? exitTime;
      for (var j = idx + 1; j < m15All.length; j++) {
        final c = m15All[j];
        final slHit = trig.isBuy ? c.low <= sl : c.high >= sl;
        final tpHit = trig.isBuy ? c.high >= tp : c.low <= tp;
        if (slHit) {
          outcome = 'خسارة';
          exit = sl;
          exitTime = c.time;
          break;
        }
        if (tpHit) {
          outcome = 'ربح';
          exit = tp;
          exitTime = c.time;
          break;
        }
      }
      final pnl = (trig.isBuy ? exit - entry : entry - exit) / TradeSetup.dollarsPerPip;
      zoneCooldown[zk] = asOf;
      openUntil = exitTime == null ? DateTime.utc(2100) : exitTime.add(const Duration(minutes: 15));
      trades.add({
        'time': candle.time,
        'dir': trig.direction.name.toUpperCase(),
        'zone': '${trig.zone.source} \$$zk',
        'shape': trig.pattern.shapeLabel,
        'entry': entry,
        'sl': sl,
        'tp': tp,
        'rr': rr,
        'clipped': clipped,
        'slPips': slPips,
        'score': sc,
        'outcome': outcome,
        'exitTime': exitTime,
        'pnl': pnl,
      });
    }

    // --------------------------------- report ---------------------------------
    final biasClosed = noTrigger[ZoneBounceReject.biasPresent] ?? 0;
    print('\n[1] حالة السوق');
    print('  شموع اتجاه HTF فيها واضح (الوحدة متنحّية): $biasClosed من ${replay.length}');
    print('  شموع الوحدة مفعّلة فيها: ${replay.length - biasClosed}');
    print('  شموع وجد المحرّك فيها ارتداداً مؤهلاً: $engineFired');

    final wins = trades.where((t) => t['outcome'] == 'ربح').toList();
    final losses = trades.where((t) => t['outcome'] == 'خسارة').toList();
    final open = trades.where((t) => t['outcome'] == 'مفتوحة').toList();
    final closedN = wins.length + losses.length;
    final closedNet = [...wins, ...losses].fold<double>(0, (a, t) => a + (t['pnl'] as double));
    final openNet = open.fold<double>(0, (a, t) => a + (t['pnl'] as double));

    print('\n[2] الأداء');
    print('  إشارات وجدها المحرّك: $engineFired   |   نُفّذت: ${trades.length}   |   رُفضت لاحقاً: ${rejectedSetups.length}');
    print('  رابحة (بلغت الهدف): ${wins.length}');
    print('  خاسرة (بلغت SL):   ${losses.length}');
    print('  مفتوحة:            ${open.length}');
    print('  نسبة الفوز (المغلقة): ${closedN == 0 ? "غير متاحة" : "${(wins.length / closedN * 100).toStringAsFixed(1)}%  ($closedN صفقة)"}');
    print('  صافي المغلقة: ${closedNet >= 0 ? "+" : ""}${closedNet.toStringAsFixed(1)} pips');
    if (open.isNotEmpty) {
      print('  عائم على المفتوحة: ${openNet >= 0 ? "+" : ""}${openNet.toStringAsFixed(1)} pips');
    }
    print('  الإجمالي (مغلقة + عائم): ${closedNet + openNet >= 0 ? "+" : ""}${(closedNet + openNet).toStringAsFixed(1)} pips');
    if (wins.isNotEmpty && losses.isNotEmpty) {
      final gw = wins.fold<double>(0, (a, t) => a + (t['pnl'] as double));
      final gl = losses.fold<double>(0, (a, t) => a + (t['pnl'] as double)).abs();
      print('  معامل الربح (Profit Factor): ${(gw / gl).toStringAsFixed(2)}');
    }
    final clippedN = trades.where((t) => t['clipped'] == true).length;
    print('  صفقات اقتُطع هدفها عند حد النطاق (≥1R): $clippedN من ${trades.length}');

    print('\n  تفصيل الصفقات:');
    for (final t in trades) {
      final pnl = t['pnl'] as double;
      print('   ${hhmm(t['time'] as DateTime)}  ${t['dir']}  ${t['zone']}  ${t['shape']}  درجة ${t['score']}');
      print('      دخول ${(t['entry'] as double).toStringAsFixed(2)}  SL ${(t['sl'] as double).toStringAsFixed(2)} '
          '(${(t['slPips'] as double).toStringAsFixed(0)}p)  TP ${(t['tp'] as double).toStringAsFixed(2)}  '
          'R:R 1:${(t['rr'] as double).toStringAsFixed(2)}${t['clipped'] == true ? " (مقتطع)" : ""}');
      print('      ⟵ ${t['outcome']}  ${pnl >= 0 ? "+" : ""}${pnl.toStringAsFixed(1)} pips'
          '${t['exitTime'] != null ? "  عند ${hhmm(t['exitTime'] as DateTime)}" : ""}');
    }

    print('\n[3] إشارات وجدها المحرّك ثم رُفضت (${rejectedSetups.length})');
    final rs = rejectedByReason.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    for (final e in rs) {
      print('   ${e.value.toString().padLeft(3)} × ${e.key}');
    }
    if (rejectedSetups.isNotEmpty) {
      print('\n   التفصيل:');
      for (final r in rejectedSetups) {
        print('   ${r['time']}  ${r['what']}  ⟵ ${r['why']}');
      }
    }

    print('\n[4] شموع لم يخرج منها أي ارتداد (السبب الأبعد وصولاً عبر البوابات)');
    final nt = noTrigger.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    for (final e in nt) {
      print('   ${e.value.toString().padLeft(3)} × ${e.key.label}');
    }
    print('${'=' * 68}\n');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
