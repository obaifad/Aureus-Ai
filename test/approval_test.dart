import 'dart:convert';

import 'package:aureus_ai/models/pivot.dart';
import 'package:aureus_ai/models/trade_setup.dart';
import 'package:aureus_ai/services/approval_service.dart';
import 'package:aureus_ai/services/data_service.dart';
import 'package:aureus_ai/services/history_store.dart';
import 'package:aureus_ai/services/mt5_trading_service.dart';
import 'package:aureus_ai/services/pending_store.dart';
import 'package:aureus_ai/services/signal_checker.dart';
import 'package:aureus_ai/services/strategy_config_service.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _now = DateTime.utc(2026, 10, 2, 12);

TradeSetup _setup({DateTime? at, double lot = 0.4}) => TradeSetup(
      symbol: 'XAUUSD',
      direction: TradeDirection.buy,
      timeframeLabel: '15M',
      setupType: SetupType.rangingBounce,
      entry: 2400,
      stopLoss: 2390,
      takeProfit: 2418,
      pattern: CandlePattern.bullishPinbar,
      detectedAt: at ?? DateTime.utc(2026, 10, 2, 11, 59),
      confluenceScore: 84,
      lotSize: lot,
    );

http.Response _json(Object body, [int status = 200]) => http.Response(jsonEncode(body), status);

PendingApproval _pending(TradeSetup s, {String engine = 'range_bounce', Duration ttl = const Duration(seconds: 90)}) =>
    PendingApproval(setup: s, engineId: engine, submittedAt: _now, expiresAt: _now.add(ttl));

void main() {
  late List<http.Request> requests;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    StrategyConfig.instance.resetForTesting();
    dotenv.testLoad(
      fileInput: 'USE_MOCK_DATA=false\nDISABLE_MT5_BRIDGE=false\nBRIDGE_BASE_URL=http://bridge.test\n'
          'MT5_SYMBOL=XAUUSD...\nRECONCILE_WITH_BROKER=false',
    );
    requests = [];
  });
  tearDown(() => StrategyConfig.instance.resetForTesting());

  Mt5TradingService trading(http.Response Function(http.Request) handler) => Mt5TradingService(
        client: MockClient((request) async {
          requests.add(request);
          return handler(request);
        }),
      );

  ApprovalService service(http.Response Function(http.Request) handler) =>
      ApprovalService(trading: trading(handler), clock: () => _now);

  group('PendingStore', () {
    test('keeps proposals across a reload and removes them by uid', () async {
      final a = _setup();
      await PendingStore.add(_pending(a));
      expect((await PendingStore.load()).single.uid, a.uid);
      expect((await PendingStore.load()).single.setup.stopLoss, 2390);
      await PendingStore.remove(a.uid);
      expect(await PendingStore.load(), isEmpty);
    });

    test('adding the same proposal twice keeps one', () async {
      final a = _setup();
      await PendingStore.add(_pending(a));
      await PendingStore.add(_pending(a));
      expect(await PendingStore.load(), hasLength(1));
    });

    test('an unreadable entry is skipped, not fatal', () async {
      SharedPreferences.setMockInitialValues({
        PendingStore.prefsKey: ['{ not json'],
      });
      expect(await PendingStore.load(), isEmpty);
    });
  });

  group('proposing', () {
    test('a proposal is posted with everything the bridge needs and then remembered', () async {
      final s = _setup();
      final expires = _now.add(const Duration(seconds: 77)).millisecondsSinceEpoch / 1000;
      final out = await service((_) => _json({'uid': s.uid, 'state': 'pending', 'expires_at': expires}))
          .submit(s, 'range_bounce');

      expect(out.isPending, isTrue);
      final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
      expect(requests.single.url.path, '/signals/pending');
      expect(body['uid'], s.uid);
      expect(body['symbol'], 'XAUUSD...');
      expect((body['direction'], body['entry'], body['stop_loss'], body['take_profit']), ('BUY', 2400, 2390, 2418));
      expect((body['volume'], body['score']), (0.4, 84));
      expect(body['label'], '15M ${SetupType.rangingBounce.label}');
      final stored = (await PendingStore.load()).single;
      expect(stored.engineId, 'range_bounce');
      expect(stored.expiresAt, _now.add(const Duration(seconds: 77)));
    });

    test('a proposal the bridge refuses is not remembered', () async {
      for (final state in ['blocked', 'failed']) {
        final out = await service((_) => _json({'state': state, 'reason': 'Spread too wide'})).submit(_setup(), 'orb');
        expect((out.state, out.reason), (state, 'Spread too wide'));
      }
      expect(await PendingStore.load(), isEmpty);
    });

    test('bridge errors (wrong mode, no Telegram, busy slot) come back as errors with the reason', () async {
      final out = await service((_) => _json({
            'detail': {'code': 'telegram_not_configured', 'message': 'Approval needs Telegram'}
          }, 409)).submit(_setup(), 'orb');
      expect(out.state, 'error');
      expect(out.reason, contains('telegram_not_configured'));
      expect(await PendingStore.load(), isEmpty);
    });

    test('an unreachable bridge is not remembered either', () async {
      final svc = ApprovalService(
        trading: Mt5TradingService(client: MockClient((_) async => throw Exception('refused'))),
        clock: () => _now,
      );
      expect((await svc.submit(_setup(), 'orb')).state, 'unreachable');
      expect(await PendingStore.load(), isEmpty);
    });
  });

  group('learning the outcome', () {
    Future<ApprovalSyncResult> syncWith(Map<String, dynamic> body, {int status = 200}) =>
        service((_) => _json(body, status)).sync();

    test('nothing waiting means no network traffic', () async {
      final r = await service((_) => _json({})).sync();
      expect((r.changedAnything, r.stillPending), (false, 0));
      expect(requests, isEmpty);
    });

    test('an executed proposal becomes a real, ticketed position in the history', () async {
      final s = _setup();
      await PendingStore.add(_pending(s));
      final r = await syncWith({
        'uid': s.uid,
        'state': 'executed',
        'result': {'ticket': 5150, 'price': 2400.35, 'volume': 0.09},
      });

      expect(r.executed, hasLength(1));
      final stored = (await HistoryStore.load()).single;
      expect(stored.brokerTicket, 5150);
      expect(stored.actualFillPrice, 2400.35);
      expect(stored.lotSize, 0.09, reason: 'the lot the bridge sized, not the app\'s proposal');
      expect(stored.dataSource, 'MT5 (approved)');
      expect(stored.outcome, TradeOutcome.open);
      expect(stored.aiReason, contains('approved this trade on Telegram'));
      expect(await PendingStore.load(), isEmpty);
    });

    test('the lookup url encodes awkward uids', () async {
      final s = _setup();
      await PendingStore.add(_pending(s));
      await syncWith({'state': 'pending'});
      expect(Uri.decodeComponent(requests.single.url.pathSegments.last), s.uid);
    });

    test('still waiting stays in the store and releases nothing', () async {
      final s = _setup();
      await PendingStore.add(_pending(s));
      final r = await syncWith({'uid': s.uid, 'state': 'pending'});
      expect((r.stillPending, r.changedAnything), (1, false));
      expect(await PendingStore.load(), hasLength(1));
      expect(await HistoryStore.load(), isEmpty);
    });

    test('rejected, expired, blocked and failed proposals are released and kept as signals nobody traded', () async {
      for (final state in ['rejected', 'expired', 'blocked', 'failed']) {
        SharedPreferences.setMockInitialValues({});
        final s = _setup();
        await PendingStore.add(_pending(s, engine: 'orb'));
        final r = await syncWith({'uid': s.uid, 'state': state});
        expect(r.released.single.state, state, reason: state);
        expect(r.released.single.approval.engineId, 'orb');
        expect(await PendingStore.load(), isEmpty, reason: state);

        final kept = (await HistoryStore.load()).single;
        expect(kept.isMissed, isTrue, reason: state);
        expect(kept.notTradedReason, state);
        expect(kept.uid, s.uid, reason: 'the same signal, so it can be matched with the Telegram message');
        expect((kept.brokerTicket, kept.lotSize, kept.actualFillPrice), (null, null, null), reason: 'no position, no lot');
        expect(kept.outcome, TradeOutcome.open, reason: 'tracked from here to its stop or target');
        expect(kept.aiReason, contains('Not traded: ${kept.notTradedLabel}'));
      }
    });

    test('a proposal whose fate is unknown is not recorded as anything', () async {
      final s = _setup();
      await PendingStore.add(_pending(s));
      final late = ApprovalService(
        trading: Mt5TradingService(client: MockClient((_) async => throw Exception('refused'))),
        clock: () => _now.add(const Duration(minutes: 30)),
      );
      expect((await late.sync()).released.single.state, 'lost');
      expect(await HistoryStore.load(), isEmpty);
    });

    test('a signal nobody traded is recorded once, however often it is released', () async {
      final s = _setup();
      for (var i = 0; i < 2; i++) {
        await PendingStore.add(_pending(s));
        await syncWith({'uid': s.uid, 'state': 'expired'});
      }
      expect(await HistoryStore.load(), hasLength(1));
    });

    test('an executed proposal is a trade, not a missed signal', () async {
      final s = _setup();
      await PendingStore.add(_pending(s));
      await syncWith({
        'uid': s.uid,
        'state': 'executed',
        'result': {'ticket': 5150, 'price': 2400.35, 'volume': 0.09},
      });
      expect((await HistoryStore.load()).single.isMissed, isFalse);
    });

    test('an executed signal without a ticket is never imported as a position', () async {
      final s = _setup();
      await PendingStore.add(_pending(s));
      final r = await syncWith({'uid': s.uid, 'state': 'executed', 'result': {}});
      expect(r.executed, isEmpty);
      expect(await HistoryStore.load(), isEmpty);
    });

    test('importing twice never duplicates the position', () async {
      final s = _setup();
      for (var i = 0; i < 2; i++) {
        await PendingStore.add(_pending(s));
        await syncWith({
          'state': 'executed',
          'result': {'ticket': 5150, 'price': 2400.35, 'volume': 0.09},
        });
      }
      expect((await HistoryStore.load()).where((t) => t.brokerTicket == 5150), hasLength(1));
    });

    test('a bare placeholder adopted by reconciliation is replaced by the full setup', () async {
      final adopted = TradeSetup(
        symbol: 'XAUUSD',
        direction: TradeDirection.buy,
        timeframeLabel: 'MT5',
        setupType: SetupType.confluence,
        entry: 2400.35,
        stopLoss: 2390,
        takeProfit: 2418,
        pattern: CandlePattern.none,
        detectedAt: _now,
        brokerTicket: 5150,
        dataSource: 'MT5 (adopted)',
      );
      await HistoryStore.mutate((h) {
        h.add(adopted);
        return true;
      });
      final s = _setup();
      await PendingStore.add(_pending(s));
      await syncWith({
        'state': 'executed',
        'result': {'ticket': 5150, 'price': 2400.35, 'volume': 0.09},
      });
      final all = await HistoryStore.load();
      expect(all, hasLength(1));
      expect(all.single.dataSource, 'MT5 (approved)');
      expect(all.single.setupType, SetupType.rangingBounce);
    });

    test('an unreachable bridge keeps proposals alive, until long after their deadline', () async {
      final s = _setup();
      await PendingStore.add(_pending(s));
      final down = ApprovalService(
        trading: Mt5TradingService(client: MockClient((_) async => throw Exception('refused'))),
        clock: () => _now.add(const Duration(minutes: 2)),
      );
      expect((await down.sync()).stillPending, 1);

      final late = ApprovalService(
        trading: Mt5TradingService(client: MockClient((_) async => throw Exception('refused'))),
        clock: () => _now.add(const Duration(minutes: 30)),
      );
      final r = await late.sync();
      expect(r.released.single.state, 'lost');
      expect(await PendingStore.load(), isEmpty);
    });

    test('a proposal the bridge has never heard of is dropped only once its deadline has clearly passed', () async {
      final s = _setup();
      await PendingStore.add(_pending(s));
      expect(
          (await syncWith({
            'detail': {'code': 'unknown_signal'}
          }, status: 404))
              .stillPending,
          1);

      final late = ApprovalService(
        trading: trading((_) => _json({'detail': {}}, 404)),
        clock: () => _now.add(const Duration(minutes: 3)),
      );
      expect((await late.sync()).released.single.state, 'lost');
    });
  });

  group('engine state is handed back', () {
    test('restoring an engine\'s captured state undoes what a signal marked', () {
      final checker = SignalChecker(clock: () => _now);
      final before = checker.debugCaptureState('range_bounce');
      checker.debugMarkFired('range_bounce');
      final after = checker.debugCaptureState('range_bounce');
      expect(after['candle'], isNotNull);
      expect((after['zones'] as Map), isNotEmpty);

      checker.debugRestoreState('range_bounce', before);
      final restored = checker.debugCaptureState('range_bounce');
      expect(restored['candle'], isNull);
      expect(restored['dir'], isNull);
      expect(restored['dirTime'], isNull);
      expect((restored['zones'] as Map), isEmpty);
    });

    test('an ORB range that a rejected proposal consumed can be used again', () {
      final checker = SignalChecker(clock: () => _now);
      final before = checker.debugCaptureState('orb');
      checker.debugMarkFired('orb');
      expect((checker.debugCaptureState('orb')['consumed'] as Set), contains('london|fired'));
      checker.debugRestoreState('orb', before);
      expect((checker.debugCaptureState('orb')['consumed'] as Set), isEmpty);
    });

    test('restoring one engine leaves the others untouched', () {
      final checker = SignalChecker(clock: () => _now);
      final rangeBefore = checker.debugCaptureState('range_bounce');
      checker.debugMarkFired('range_bounce');
      checker.debugMarkFired('htf_retest');
      checker.debugRestoreState('range_bounce', rangeBefore);
      expect(checker.debugCaptureState('htf_retest')['candle'], isNotNull);
    });

    test('a captured snapshot is a copy: later signals do not leak into it', () {
      final checker = SignalChecker(clock: () => _now);
      final before = checker.debugCaptureState('range_bounce');
      checker.debugMarkFired('range_bounce');
      expect((before['zones'] as Map), isEmpty);
    });

    test('a cooling engine is quiet for exactly its cooldown', () {
      var now = _now;
      final checker = SignalChecker(clock: () => now);
      expect(checker.debugCooling('orb'), isFalse);
      checker.debugCool('orb', const Duration(minutes: 15));
      expect(checker.debugCooling('orb'), isTrue);
      now = _now.add(const Duration(minutes: 14, seconds: 59));
      expect(checker.debugCooling('orb'), isTrue);
      now = _now.add(const Duration(minutes: 15));
      expect(checker.debugCooling('orb'), isFalse);
    });

    test('the cooldown length comes from the bridge config, 15 minutes by default', () {
      expect(StrategyConfigSnapshot.empty.rejectCooldownMinutes, 15);
      final snap = StrategyConfigSnapshot.fromResponse({
        'revision': 3,
        'config': {
          'trade_rules': {'reject_cooldown_minutes': 40}
        },
      });
      expect(snap.rejectCooldownMinutes, 40);
    });
  });

  group('SignalChecker scans with proposals in flight', () {
    http.Response bridge(http.Request request, {required Map<String, dynamic> signal}) {
      switch (request.url.path) {
        case '/risk/status':
          return _json({'available': true, 'locked': false, 'limit_percent': 3.0, 'loss_percent': 0.0});
      }
      if (request.url.path.startsWith('/signals/')) return _json(signal);
      return http.Response('not found', 404);
    }

    Future<SignalCheckResult> scan(SignalChecker checker, Map<String, dynamic> signal) {
      final client = MockClient((request) async {
        requests.add(request);
        return bridge(request, signal: signal);
      });
      return http.runWithClient(() => checker.check(), () => client);
    }

    SignalChecker newChecker() => SignalChecker(dataServiceFactory: () => MockDataService());

    test('a proposal waiting for the owner blocks new signals and says so', () async {
      final s = _setup(at: DateTime.now().toUtc());
      await PendingStore.add(PendingApproval(
        setup: s,
        engineId: 'range_bounce',
        submittedAt: DateTime.now().toUtc(),
        expiresAt: DateTime.now().toUtc().add(const Duration(seconds: 90)),
      ));
      final result = await scan(newChecker(), {'uid': s.uid, 'state': 'pending'});
      expect(result.setups, isEmpty);
      expect(result.status, contains('Awaiting your Telegram approval'));
      expect(result.status, contains('@ 2400.0'));
    });

    test('once the owner rejects, the engine is released and goes quiet', () async {
      final s = _setup(at: DateTime.now().toUtc());
      await PendingStore.add(PendingApproval(
        setup: s,
        engineId: 'range_bounce',
        submittedAt: DateTime.now().toUtc(),
        expiresAt: DateTime.now().toUtc().add(const Duration(seconds: 90)),
      ));
      final checker = newChecker();
      final result = await scan(checker, {'uid': s.uid, 'state': 'rejected'});
      expect(await PendingStore.load(), isEmpty);
      expect(checker.debugCooling('range_bounce'), isTrue);
      expect(result.status, contains('Engines quiet after a decision: range_bounce'));
      expect(result.status, isNot(contains('Awaiting your Telegram approval')));
    });

    test('a signal nobody traded never holds back the next one', () async {
      final missed = _setup(at: DateTime.now().toUtc())..notTradedReason = 'expired';
      await HistoryStore.mutate((h) {
        h.add(missed);
        return true;
      });
      final result = await scan(newChecker(), {'state': 'pending'});
      expect(missed.outcome, TradeOutcome.open);
      expect(result.status, isNot(contains('One Active Trade Limit')));
    });

    test('a real open trade still does', () async {
      final real = _setup(at: DateTime.now().toUtc());
      await HistoryStore.mutate((h) {
        h.add(real);
        return true;
      });
      final result = await scan(newChecker(), {'state': 'pending'});
      expect(result.status, contains('One Active Trade Limit'));
    });

    test('an expired proposal appears in the history as not traded, and the engine is quiet', () async {
      final s = _setup(at: DateTime.now().toUtc());
      await PendingStore.add(PendingApproval(
        setup: s,
        engineId: 'range_bounce',
        submittedAt: DateTime.now().toUtc(),
        expiresAt: DateTime.now().toUtc().add(const Duration(seconds: 90)),
      ));
      final checker = newChecker();
      await scan(checker, {'uid': s.uid, 'state': 'expired'});
      final kept = (await HistoryStore.load()).where((h) => h.uid == s.uid).single;
      expect(kept.notTradedReason, 'expired');
      expect(checker.debugCooling('range_bounce'), isTrue);
    });

    test('an approved trade is imported even though the scan then stops for the open position', () async {
      final s = _setup(at: DateTime.now().toUtc());
      await PendingStore.add(PendingApproval(
        setup: s,
        engineId: 'range_bounce',
        submittedAt: DateTime.now().toUtc(),
        expiresAt: DateTime.now().toUtc().add(const Duration(seconds: 90)),
      ));
      final result = await scan(newChecker(), {
        'uid': s.uid,
        'state': 'executed',
        'result': {'ticket': 777, 'price': 2400.2, 'volume': 0.1},
      });
      final history = await HistoryStore.load();
      expect(history.single.brokerTicket, 777);
      expect(await PendingStore.load(), isEmpty);
      expect(result.status, contains('One Active Trade Limit'));
    });
  });
}
