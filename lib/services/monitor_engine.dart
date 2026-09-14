import 'dart:async';

import '../config/app_config.dart';
import '../models/pivot.dart';
import '../models/trade_setup.dart';
import 'app_logger.dart';
import 'history_store.dart';
import 'signal_checker.dart';
import 'tick_stream_service.dart';

/// Events MonitorEngine emits. They are plain JSON-safe maps so the exact
/// same payload can cross the foreground-service → UI isolate boundary via
/// FlutterForegroundTask.sendDataToMain, or be delivered in-process on
/// desktop.
///   {'type': 'cycle', 'status': String, 'ok': bool, 'feed': String?,
///    'livePrice': double?, 'newSignals': int, 'at': ISO-8601}
///   {'type': 'history'}                       — persisted history changed
///   {'type': 'tickConn', 'connected': bool}   — tick WebSocket state
typedef MonitorEventSink = void Function(Map<String, Object?> event);

/// Everything that makes monitoring actually work, owned by exactly ONE
/// isolate at a time — the Android foreground-service isolate while the
/// service runs, otherwise the UI isolate (desktop, or a manual scan on
/// mobile with monitoring stopped). Keeping the scanner, the tick fast path
/// and every history write in one place removes the cross-isolate write
/// races and the duplicate signals two independent SignalCheckers produced.
class MonitorEngine {
  final MonitorEventSink onEvent;
  MonitorEngine({required this.onEvent});

  final SignalChecker _checker = SignalChecker();

  TickStreamService? _ticks;
  StreamSubscription<Tick>? _tickSub;
  StreamSubscription<bool>? _connSub;

  bool _cycleRunning = false;
  bool _tickBusy = false;
  Tick? _pendingTick;

  /// In-memory copy of the currently OPEN setups, so the ~3 ticks/second
  /// only touch storage when a level has actually been crossed.
  List<TradeSetup> _open = const [];

  Future<void> init() => _refreshOpenCache();

  Future<void> _refreshOpenCache() async {
    final history = await HistoryStore.load();
    _open = history.where((s) => s.outcome == TradeOutcome.open).toList();
  }

  /// One full scan cycle. Returns null if a cycle is already running.
  Future<Map<String, Object?>?> runCycle() async {
    if (_cycleRunning) return null;
    _cycleRunning = true;
    try {
      final result = await _checker.check();

      var added = <TradeSetup>[];
      if (result.setups.isNotEmpty) {
        await HistoryStore.mutate((history) {
          added = result.setups.where((s) {
            final duplicate = history.any((h) => h.isDuplicateOf(s));
            if (duplicate) AppLogger.log('Duplicate ${s.setupLabel} @ ${s.entry} dropped (already in history)');
            return !duplicate;
          }).toList();
          history.insertAll(0, added);
          return added.isNotEmpty;
        });

        // AI commentary + notifications only for genuinely new setups; the
        // AI text is persisted afterwards (it may take a few seconds).
        for (final setup in added) {
          await _checker.finalizeSetup(setup);
        }
        if (added.isNotEmpty) {
          await HistoryStore.mutate((history) {
            var changed = false;
            for (final setup in added) {
              final stored = history.where((h) => h.uid == setup.uid);
              for (final h in stored) {
                h.aiReason = setup.aiReason;
                changed = true;
              }
            }
            return changed;
          });
        }
      }

      await _refreshOpenCache();
      final event = <String, Object?>{
        'type': 'cycle',
        'status': result.status,
        'ok': true,
        'feed': result.feed?.name,
        'livePrice': result.livePrice,
        'newSignals': added.length,
        'at': DateTime.now().toUtc().toIso8601String(),
      };
      onEvent(event);
      onEvent({'type': 'history'});
      return event;
    } catch (e, st) {
      AppLogger.log('Scan cycle error: $e\n${st.toString().split('\n').take(6).join('\n')}');
      final event = <String, Object?>{
        'type': 'cycle',
        'status': 'Error: $e',
        'ok': false,
        'at': DateTime.now().toUtc().toIso8601String(),
      };
      onEvent(event);
      return event;
    } finally {
      _cycleRunning = false;
    }
  }

  /// Starts the sub-second SL/TP fast path (bridge only; no-op in mock mode).
  void startTicks() {
    if (AppConfig.useMockData || AppConfig.disableMt5Bridge || _ticks != null) return;
    final ticks = TickStreamService();
    _ticks = ticks;
    _tickSub = ticks.connect(symbol: AppConfig.brokerSymbol).listen(_onTick);
    _connSub = ticks.connectionStatus.listen((connected) => onEvent({'type': 'tickConn', 'connected': connected}));
  }

  void stopTicks() {
    _tickSub?.cancel();
    _connSub?.cancel();
    _ticks?.dispose();
    _tickSub = null;
    _connSub = null;
    _ticks = null;
  }

  /// Forces a fresh tick connection (e.g. after the app returns from the
  /// background, where the socket may have been silently killed).
  void restartTicks() {
    if (_ticks == null) return;
    stopTicks();
    startTicks();
  }

  Future<void> _onTick(Tick tick) async {
    if (_open.isEmpty) return;
    final crossed = _open.any((s) => s.evaluateOutcomeAtTick(bid: tick.bid, ask: tick.ask) != null);
    if (!crossed) return;

    // Serialize: ticks keep arriving while storage is being updated. Only the
    // most recent pending tick matters.
    if (_tickBusy) {
      _pendingTick = tick;
      return;
    }
    _tickBusy = true;
    try {
      Tick? current = tick;
      while (current != null) {
        final changed = await _checker.resolveOpenTradesAtTick(bid: current.bid, ask: current.ask);
        if (changed) {
          await _refreshOpenCache();
          onEvent({'type': 'history'});
        }
        current = _pendingTick;
        _pendingTick = null;
        if (current != null &&
            !_open.any((s) => s.evaluateOutcomeAtTick(bid: current!.bid, ask: current.ask) != null)) {
          current = null;
        }
      }
    } catch (e) {
      AppLogger.log('Tick outcome check failed: $e');
    } finally {
      _tickBusy = false;
    }
  }

  void dispose() => stopTicks();
}
