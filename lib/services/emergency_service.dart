import 'package:http/http.dart' as http;

import 'app_logger.dart';
import 'history_store.dart';
import 'mt5_trading_service.dart';
import 'strategy_config_service.dart';

/// What an emergency stop actually did, in plain counts the UI can show.
class EmergencyResult {
  /// New signals/orders are now blocked on the bridge (mode.paused).
  final bool paused;

  /// MT5 positions closed by this request.
  final int closed;

  /// MT5 positions that could NOT be closed — these are still open.
  final int failed;

  /// App trades that were open and are now recorded as closed.
  final int recordedLocally;
  final List<String> problems;

  const EmergencyResult({
    required this.paused,
    required this.closed,
    required this.failed,
    required this.recordedLocally,
    required this.problems,
  });

  bool get allClear => paused && failed == 0 && problems.isEmpty;

  String get summary {
    final parts = <String>[
      paused ? 'Trading paused.' : 'COULD NOT pause trading.',
      closed == 0 && failed == 0 ? 'No open MT5 positions.' : '$closed position(s) closed.',
      if (failed > 0) '$failed position(s) STILL OPEN — close them in MetaTrader.',
    ];
    return parts.join(' ');
  }
}

/// The big red button: pause first (so nothing new can open while closing),
/// then close every open position on the bridge, then record those closes in
/// the app's own history. Each step is independent — a failed pause never
/// stops the closing, and a failed close is reported, never hidden.
class EmergencyService {
  EmergencyService({Mt5TradingService? trading, http.Client? client})
      : _trading = trading ?? Mt5TradingService(client: client),
        _client = client;

  final Mt5TradingService _trading;
  final http.Client? _client;

  Future<EmergencyResult> closeAllAndPause() async {
    final problems = <String>[];
    AppLogger.log('🚨 EMERGENCY STOP requested — pausing and closing all positions');

    final paused = await _pause(problems);

    final outcome = await _trading.closeAllPositions();
    if (outcome.error != null && outcome.results.isEmpty) {
      problems.add('Close-all: ${outcome.error}');
    }
    final closedPrices = {
      for (final r in outcome.results)
        if (r.success) r.ticket: r.price,
    };
    final failed = outcome.results.where((r) => !r.success).toList();
    for (final r in failed) {
      problems.add('#${r.ticket}: ${r.error ?? 'close failed'}');
    }

    var recorded = 0;
    if (closedPrices.isNotEmpty) {
      try {
        await HistoryStore.mutate((history) {
          for (final setup in history) {
            final ticket = setup.brokerTicket;
            if (ticket == null || !closedPrices.containsKey(ticket)) continue;
            final price = closedPrices[ticket];
            if (price != null && setup.closeTradeManually(price)) recorded++;
          }
          return recorded > 0;
        });
      } catch (e) {
        problems.add('Could not update the trade history: $e');
      }
    }

    final result = EmergencyResult(
      paused: paused,
      closed: closedPrices.length,
      failed: failed.length,
      recordedLocally: recorded,
      problems: problems,
    );
    AppLogger.log('🚨 EMERGENCY STOP done — ${result.summary}');
    return result;
  }

  Future<bool> _pause(List<String> problems) async {
    final config = StrategyConfig.instance;
    final view = await config.fetchView(client: _client);
    if (view == null) {
      problems.add('Could not reach the bridge config to pause trading.');
      return false;
    }
    if (view.valueAt('mode.paused') == true) return true;
    final result = await config.update(
      {
        'mode': {'paused': true},
      },
      baseRevision: view.revision,
      client: _client,
    );
    if (!result.ok) problems.add('Pause: ${result.message}');
    return result.ok;
  }
}
