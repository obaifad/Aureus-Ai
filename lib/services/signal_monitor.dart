import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import '../models/trade_setup.dart';
import 'app_logger.dart';
import 'connection_status_service.dart';
import 'history_store.dart';
import 'monitor_engine.dart';
import 'monitor_task_handler.dart';

/// Persists whether monitoring was intentionally ON, so it auto-resumes on a
/// fresh app process without tapping Start again.
const _shouldRunPrefsKey = 'aureus_monitor_should_run_v1';

/// UI-side orchestrator (ChangeNotifier).
///
/// Android/iOS: monitoring runs in the foreground-service isolate
/// (MonitorTaskHandler → MonitorEngine). This class only mirrors its state:
/// it receives events through the communication port and re-reads history
/// from HistoryStore — it never writes history itself while the service
/// runs, so there is exactly one writer.
///
/// Desktop/web (no foreground service), or a manual scan on mobile while the
/// service is stopped: a local [MonitorEngine] runs in this isolate.
class SignalMonitor extends ChangeNotifier with WidgetsBindingObserver {
  MonitorEngine? _localEngine;
  Timer? _timer;

  bool _isRunning = false;
  bool _isChecking = false;
  bool _disposed = false;
  String _status = 'Idle';
  DateTime? _lastCheck;
  DateTime? _lastSuccessfulCheck;
  FeedSource? _feed;
  double? _livePrice;
  bool? _tickConnected;

  List<TradeSetup> _history = const [];

  bool get isRunning => _isRunning;
  bool get isChecking => _isChecking;
  String get status => _status;
  DateTime? get lastCheck => _lastCheck;
  DateTime? get lastSuccessfulCheck => _lastSuccessfulCheck;
  FeedSource? get feed => _feed;
  double? get livePrice => _livePrice;

  /// null = no tick stream (mock mode / not started yet).
  bool? get tickConnected => _tickConnected;
  List<TradeSetup> get history => List.unmodifiable(_history);

  static bool get _useForegroundService => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  SignalMonitor() {
    WidgetsBinding.instance.addObserver(this);
    if (_useForegroundService) {
      _initForegroundTask();
      FlutterForegroundTask.addTaskDataCallback(_onTaskData);
    }
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    await _reloadHistory();
    try {
      if (_useForegroundService && await FlutterForegroundTask.isRunningService) {
        // The service outlived the previous UI process — adopt it instead of
        // trying to start it again (which throws ServiceAlreadyStarted).
        _isRunning = true;
        _status = 'Monitoring ${AppConfig.symbol} (background service)';
        _notify();
        FlutterForegroundTask.sendDataToTask(MonitorCommand.scan);
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_shouldRunPrefsKey) ?? false) {
        await start();
      }
    } catch (e) {
      AppLogger.log('SignalMonitor bootstrap failed: $e');
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(_reloadHistory());
    unawaited(AppLogger.refreshFromDisk());
    if (!_isRunning) return;
    if (_useForegroundService) {
      // Background sockets can be silently killed while the screen is off.
      FlutterForegroundTask.sendDataToTask(MonitorCommand.reconnectTicks);
    } else {
      _localEngine?.restartTicks();
    }
  }

  void _initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'aureus_monitor',
        channelName: 'Aureus AI Monitoring',
        channelDescription: 'Keeps watching XAUUSD for a confluence signal while the app is backgrounded.',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(AppConfig.pollInterval.inMilliseconds),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  MonitorEngine _ensureLocalEngine() {
    return _localEngine ??= MonitorEngine(onEvent: _handleEvent)..init();
  }

  Future<void> start() async {
    if (_isRunning) return;

    if (_useForegroundService) {
      try {
        final permission = await FlutterForegroundTask.checkNotificationPermission();
        if (permission != NotificationPermission.granted) {
          await FlutterForegroundTask.requestNotificationPermission();
        }
        if (Platform.isAndroid && !await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
          // Doze otherwise cuts network access for the service.
          await FlutterForegroundTask.requestIgnoreBatteryOptimization();
        }

        if (!await FlutterForegroundTask.isRunningService) {
          final result = await FlutterForegroundTask.startService(
            serviceId: 256,
            notificationTitle: 'Aureus AI — monitoring ${AppConfig.symbol}',
            notificationText: 'Starting…',
            callback: startMonitorCallback,
          );
          if (result is ServiceRequestFailure) {
            _status = 'Error: could not start background service (${result.error})';
            AppLogger.log(_status);
            _notify();
            return;
          }
        }
      } catch (e) {
        _status = 'Error: could not start background service ($e)';
        AppLogger.log(_status);
        _notify();
        return;
      }
    } else {
      final engine = _ensureLocalEngine();
      engine.startTicks();
      unawaited(_runLocalCycle());
      _timer = Timer.periodic(AppConfig.pollInterval, (_) => _runLocalCycle());
    }

    _isRunning = true;
    _status = 'Monitoring ${AppConfig.symbol}';
    AppLogger.log('Monitoring started');
    _notify();
    unawaited(_persistShouldRun(true));
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _localEngine?.stopTicks();
    if (_useForegroundService) {
      try {
        await FlutterForegroundTask.stopService();
      } catch (e) {
        AppLogger.log('stopService failed: $e');
      }
    }
    _isRunning = false;
    _tickConnected = null;
    _status = 'Stopped';
    AppLogger.log('Monitoring stopped');
    _notify();
    unawaited(_persistShouldRun(false));
  }

  Future<void> _persistShouldRun(bool shouldRun) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_shouldRunPrefsKey, shouldRun);
    } catch (_) {}
  }

  /// Events from the foreground-service isolate.
  void _onTaskData(Object data) {
    if (data is Map) _handleEvent(Map<String, Object?>.from(data));
  }

  /// Shared handler for engine events, whichever isolate produced them.
  void _handleEvent(Map<String, Object?> event) {
    switch (event['type']) {
      case 'cycle':
        _status = (event['status'] as String?) ?? _status;
        _lastCheck = DateTime.now();
        if (event['ok'] == true) _lastSuccessfulCheck = DateTime.now();
        final feedName = event['feed'] as String?;
        _feed = feedName == null ? null : FeedSource.values.asNameMap()[feedName];
        _livePrice = (event['livePrice'] as num?)?.toDouble() ?? _livePrice;
        _isChecking = false;
        _notify();
      case 'history':
        unawaited(_reloadHistory());
      case 'tickConn':
        _tickConnected = event['connected'] == true;
        _notify();
    }
  }

  Future<void> _runLocalCycle() async {
    if (_isChecking) return;
    _isChecking = true;
    _status = 'Scanning…';
    _notify();
    try {
      await _ensureLocalEngine().runCycle();
    } finally {
      _isChecking = false;
      _notify();
    }
  }

  /// Manual Scan. On mobile with the service running the request is
  /// forwarded to the service's engine (a second engine here would race it
  /// and duplicate signals); otherwise it runs locally.
  Future<void> runManualScan() async {
    if (_useForegroundService && await FlutterForegroundTask.isRunningService) {
      _isChecking = true;
      _status = 'Scan requested…';
      _notify();
      FlutterForegroundTask.sendDataToTask(MonitorCommand.scan);
      // Cleared by the next 'cycle' event; safety timeout in case the
      // service is busy with a cycle already (it then skips the request).
      Timer(const Duration(seconds: 20), () {
        if (_isChecking) {
          _isChecking = false;
          _notify();
        }
      });
      return;
    }
    await _runLocalCycle();
  }

  Future<void> _reloadHistory() async {
    _history = await HistoryStore.load();
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _localEngine?.dispose();
    if (_useForegroundService) {
      FlutterForegroundTask.removeTaskDataCallback(_onTaskData);
    }
    super.dispose();
  }
}
