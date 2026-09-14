import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';

/// Where the candles GoldChartScreen is currently drawing actually came
/// from (2026-09-13 — MT5 Bridge Connection Refused / automated-failover
/// request). Only meaningful outside mock mode (AppConfig.useMockData) —
/// mock mode never touches this service at all, since choosing mock is a
/// deliberate user setting, not a failure state.
enum FeedSource {
  /// The real MT5 bridge server answered normally.
  liveBridge,

  /// The bridge was unreachable and TwelveData's free-tier XAU/USD SPOT
  /// feed was used instead — real market data, and (unlike the Yahoo
  /// tier below) actual spot gold rather than a futures proxy. Tried
  /// before Yahoo; skipped automatically if no TWELVE_DATA_API_KEY is
  /// configured in .env, or if its free-tier rate limit was just hit.
  fallbackTwelveData,

  /// The bridge (and TwelveData) were unreachable and Yahoo Finance's
  /// public GC=F feed was used instead — real market data, but
  /// futures-based and not tick-identical to the broker's own XAUUSD
  /// spot price.
  fallbackYahoo,

  /// Neither the bridge, TwelveData, nor Yahoo Finance answered.
  /// GoldChartScreen keeps whatever candles it last successfully drew
  /// rather than fabricating
  /// new ones — this is an honest "last known data, feed is down" state,
  /// not a live one.
  disconnected,
}

extension FeedSourceLabel on FeedSource {
  String get label => switch (this) {
        FeedSource.liveBridge => 'MT5 Bridge',
        FeedSource.fallbackTwelveData => 'TwelveData XAU/USD',
        FeedSource.fallbackYahoo => 'Yahoo GC=F (futures)',
        FeedSource.disconnected => 'Disconnected',
      };

  /// True for feeds whose prices are spot XAUUSD (comparable to the
  /// broker's chart). Yahoo's GC=F is futures and is not.
  bool get isSpot => this == FeedSource.liveBridge || this == FeedSource.fallbackTwelveData;
}

/// Single source of truth for the MT5 bridge's live/down state, shared by
/// [FailoverDataService] (which reports every fetch outcome here) and
/// GoldChartScreen (which reads [statusStream] for its connection badge).
///
/// Also owns the background `/health` poll (explicit request, 2026-09-13:
/// "Continuously poll the /health endpoint every 10 seconds in the
/// background. Once the Python MT5 Bridge server comes back online,
/// automatically restore the live tick-by-tick stream without requiring
/// an app restart.") — this timer is independent of however often a
/// screen fetches its own candles, so recovery is detected on a fixed
/// cadence even if a screen's own poll interval changes, and
/// [bridgeRestored] lets a screen react immediately (force a reload) the
/// moment the bridge comes back, instead of waiting for its own next
/// scheduled fetch to happen to succeed.
class ConnectionStatusService {
  ConnectionStatusService._();
  static final ConnectionStatusService instance = ConnectionStatusService._();

  final StreamController<FeedSource> _statusController = StreamController<FeedSource>.broadcast();
  Stream<FeedSource> get statusStream => _statusController.stream;
  FeedSource _current = FeedSource.disconnected;
  FeedSource get current => _current;

  final StreamController<void> _restoredController = StreamController<void>.broadcast();
  /// Fires exactly once each time the bridge's `/health` transitions from
  /// down to healthy.
  Stream<void> get bridgeRestored => _restoredController.stream;

  Timer? _healthTimer;
  bool _lastHealthy = false;

  /// Called by [FailoverDataService] after every fetch attempt so the
  /// badge always reflects where the candles just drawn actually came
  /// from — not a separate/possibly-stale health check.
  void report(FeedSource source) {
    if (source == _current) return;
    _current = source;
    _statusController.add(source);
  }

  Future<bool> pingBridgeHealth() async {
    try {
      final uri = Uri.parse('${AppConfig.bridgeBaseUrl}/health');
      final response = await http.get(uri).timeout(const Duration(seconds: 4));
      if (response.statusCode != 200) return false;
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      return body['connected'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Idempotent — safe to call from every screen that cares about
  /// recovery; only the first call actually starts the timer.
  void startHealthPolling() {
    if (_healthTimer != null || AppConfig.useMockData || AppConfig.disableMt5Bridge) return;
    _healthTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      final healthy = await pingBridgeHealth();
      if (healthy && !_lastHealthy) {
        _restoredController.add(null);
      }
      _lastHealthy = healthy;
    });
  }

  void stopHealthPolling() {
    _healthTimer?.cancel();
    _healthTimer = null;
  }
}
