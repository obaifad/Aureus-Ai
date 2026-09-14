import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../config/app_config.dart';
import 'app_logger.dart';

/// One tick pushed by the bridge's `/stream/ticks` WebSocket endpoint (see
/// bridge/mt5_bridge_server.py). [time] is real UTC with millisecond
/// precision (the bridge converts MT5's broker-server time).
class Tick {
  final DateTime time;
  final double bid;
  final double ask;
  final double last;
  const Tick({required this.time, required this.bid, required this.ask, required this.last});

  double get spread => ask - bid;

  factory Tick.fromJson(Map<String, dynamic> json) {
    final timeMsc = json['time_msc'] as num?;
    final bid = (json['bid'] as num).toDouble();
    return Tick(
      time: timeMsc != null
          ? DateTime.fromMillisecondsSinceEpoch(timeMsc.toInt(), isUtc: true)
          : DateTime.fromMillisecondsSinceEpoch((json['time'] as num).toInt() * 1000, isUtc: true),
      bid: bid,
      ask: (json['ask'] as num?)?.toDouble() ?? bid,
      last: (json['last'] as num?)?.toDouble() ?? bid,
    );
  }
}

/// Live tick streaming client with:
///  - exponential reconnect backoff (1s → 30s, reset on the first frame),
///  - a watchdog: the bridge sends a heartbeat every 5s even when price is
///    quiet, so 15s of total silence means a half-open socket (Wi-Fi switch,
///    NAT timeout) and the connection is torn down and reopened instead of
///    silently freezing,
///  - [connectionStatus] emitting only on actual changes.
///
/// Never used in mock mode (AppConfig.useMockData).
class TickStreamService {
  static const Duration _watchdogTimeout = Duration(seconds: 15);
  static const Duration _maxBackoff = Duration(seconds: 30);

  WebSocketChannel? _channel;
  StreamSubscription? _channelSub;
  final StreamController<Tick> _controller = StreamController<Tick>.broadcast();
  final StreamController<bool> _connectionController = StreamController<bool>.broadcast();
  Timer? _reconnectTimer;
  Timer? _watchdog;
  bool _disposed = false;
  bool? _connected;
  int _failures = 0;
  String _symbol = AppConfig.brokerSymbol;

  Tick? lastTick;

  Stream<bool> get connectionStatus => _connectionController.stream;
  bool get isConnected => _connected == true;

  Stream<Tick> connect({String? symbol}) {
    _symbol = symbol ?? AppConfig.brokerSymbol;
    if (_channel == null && _reconnectTimer == null) _open();
    return _controller.stream;
  }

  void _setConnected(bool value) {
    if (_disposed || _connected == value) return;
    _connected = value;
    _connectionController.add(value);
    AppLogger.log(value ? 'Tick stream connected' : 'Tick stream disconnected');
  }

  void _open() {
    _reconnectTimer = null;
    if (_disposed) return;
    try {
      final wsBase = AppConfig.bridgeBaseUrl.replaceFirst(RegExp(r'^http'), 'ws');
      final uri = Uri.parse('$wsBase/stream/ticks').replace(queryParameters: {
        'symbol': _symbol,
        if (AppConfig.bridgeApiKey.isNotEmpty) 'api_key': AppConfig.bridgeApiKey,
      });
      final channel = WebSocketChannel.connect(uri);
      _channel = channel;
      _armWatchdog(); // also bounds a handshake that never completes

      // Connection failures surface asynchronously on `ready`, not as a
      // synchronous throw — handle them there so they never reach the zone
      // as unhandled exceptions.
      channel.ready.then((_) {
        if (!identical(_channel, channel)) return;
        _armWatchdog();
      }).catchError((Object e) {
        if (!identical(_channel, channel)) return;
        _handleDrop('connect failed: $e');
      });

      _channelSub = channel.stream.listen(
        (data) {
          if (!identical(_channel, channel)) return;
          _armWatchdog();
          if (data is! String || data.isEmpty) return;
          try {
            final json = jsonDecode(data) as Map<String, dynamic>;
            _failures = 0;
            _setConnected(true);
            if (json['type'] == 'hb') return; // heartbeat
            final tick = Tick.fromJson(json);
            lastTick = tick;
            _controller.add(tick);
          } catch (e) {
            AppLogger.log('Tick stream: malformed frame ignored: ${_redact(e.toString())}');
          }
        },
        onError: (Object e) {
          if (identical(_channel, channel)) _handleDrop('socket error: $e');
        },
        onDone: () {
          if (identical(_channel, channel)) {
            _handleDrop('closed (code ${channel.closeCode ?? "-"} ${channel.closeReason ?? ""})');
          }
        },
        cancelOnError: true,
      );
    } catch (e) {
      _handleDrop('open failed: $e');
    }
  }

  void _armWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer(_watchdogTimeout, () => _handleDrop('no data for ${_watchdogTimeout.inSeconds}s (watchdog)'));
  }

  /// Strips the bridge API key out of error text before it's ever logged —
  /// connection-failure exceptions embed the full request URL (WebSocket
  /// libraries put it in their own toString()), and System Logs is
  /// copy/share-able.
  static String _redact(String text) => text.replaceAll(RegExp(r'api_key=[^&\s'
      "'"
      r']+'), 'api_key=***');

  void _handleDrop(String rawReason) {
    if (_disposed) return;
    final reason = _redact(rawReason);
    _watchdog?.cancel();
    _channelSub?.cancel();
    _channelSub = null;
    final channel = _channel;
    _channel = null;
    try {
      channel?.sink.close();
    } catch (_) {}

    // Log the reason only on the first failure of a streak, so a bridge that
    // is simply offline doesn't write a line every few seconds.
    if (_failures == 0) AppLogger.log('Tick stream dropped: $reason');
    _setConnected(false);

    final backoffSeconds = min(_maxBackoff.inSeconds, pow(2, _failures).toInt());
    _failures++;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: backoffSeconds), _open);
  }

  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _watchdog?.cancel();
    _channelSub?.cancel();
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    _controller.close();
    _connectionController.close();
  }
}
