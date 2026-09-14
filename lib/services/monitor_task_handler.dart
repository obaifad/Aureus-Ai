import 'dart:async';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../config/app_config.dart';
import 'app_logger.dart';
import 'monitor_engine.dart';

/// Commands the UI isolate can send with FlutterForegroundTask.sendDataToTask.
class MonitorCommand {
  MonitorCommand._();
  static const scan = 'scan';
  static const reconnectTicks = 'reconnectTicks';
}

/// Runs [MonitorEngine] inside the Android/iOS foreground-service isolate.
///
/// This isolate shares NOTHING in memory with the UI isolate: `.env` must be
/// loaded again here (otherwise every AppConfig read failed with
/// NotInitializedError and no cycle ever completed), logging goes through
/// AppLogger's shared file, history through HistoryStore, and results are
/// streamed back with sendDataToMain (which requires
/// FlutterForegroundTask.initCommunicationPort() in main()).
class MonitorTaskHandler extends TaskHandler {
  MonitorEngine? _engine;
  final Completer<void> _ready = Completer<void>();

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await AppLogger.init(isolateTag: 'BG');
    try {
      await dotenv.load(fileName: '.env');
    } catch (e) {
      AppLogger.log('Background isolate: failed to load .env ($e) — running with defaults');
    }
    AppLogger.log('Foreground monitor service started ($starter) — '
        '${AppConfig.useMockData ? "MOCK data" : "live feed via ${AppConfig.bridgeBaseUrl}"}');

    final engine = MonitorEngine(onEvent: FlutterForegroundTask.sendDataToMain);
    await engine.init();
    engine.startTicks();
    _engine = engine;
    _ready.complete();

    unawaited(_runCycle()); // don't wait a full poll interval for the first scan
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    unawaited(_runCycle());
  }

  Future<void> _runCycle() async {
    await _ready.future;
    final event = await _engine?.runCycle();
    if (event == null) return;
    final status = (event['status'] as String?) ?? '';
    final ok = event['ok'] == true;
    final short = status.length > 90 ? '${status.substring(0, 90)}…' : status;
    try {
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Aureus AI — monitoring ${AppConfig.symbol}',
        notificationText: ok ? short : 'Error — open the app for details',
      );
    } catch (_) {}
  }

  @override
  void onReceiveData(Object data) {
    if (data == MonitorCommand.scan) {
      unawaited(_runCycle());
    } else if (data == MonitorCommand.reconnectTicks) {
      _engine?.restartTicks();
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    _engine?.dispose();
    AppLogger.log('Foreground monitor service stopped');
  }
}

/// Entry point the OS spawns in a separate isolate for the foreground
/// service. Must stay a top-level function per the plugin's contract.
@pragma('vm:entry-point')
void startMonitorCallback() {
  FlutterForegroundTask.setTaskHandler(MonitorTaskHandler());
}
