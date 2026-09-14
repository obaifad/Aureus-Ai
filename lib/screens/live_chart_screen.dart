import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:provider/provider.dart';

import '../config/app_config.dart';
import '../models/candle.dart';
import '../models/pivot.dart';
import '../models/trade_setup.dart';
import '../services/app_logger.dart';
import '../services/connection_status_service.dart';
import '../services/data_service.dart';
import '../services/signal_monitor.dart';
import '../services/tick_stream_service.dart';

/// Candlestick chart drawn from the SAME data pipeline the signal engine
/// uses (MT5 bridge → TwelveData → Yahoo failover), updated tick-by-tick
/// from the bridge WebSocket, with every open trade's Entry / SL / TP drawn
/// on it — so what you see is exactly what the signals were computed from.
class LiveChartScreen extends StatefulWidget {
  const LiveChartScreen({super.key});

  @override
  State<LiveChartScreen> createState() => _LiveChartScreenState();
}

class _LiveChartScreenState extends State<LiveChartScreen> {
  static const _timeframes = [AppConfig.tfM15, AppConfig.tfH1, AppConfig.tfH4];

  final DataService _data = DataService();
  TickStreamService? _ticks;
  StreamSubscription<Tick>? _tickSub;
  StreamSubscription<bool>? _connSub;
  StreamSubscription<void>? _restoredSub;
  Timer? _refreshTimer;

  int _tf = AppConfig.tfM15;
  List<Candle> _candles = const [];
  bool _loading = true;
  bool _refreshing = false;
  String? _error;
  DateTime? _lastRefresh;
  FeedSource? _feed;
  Tick? _lastTick;
  bool? _tickConnected;

  // Viewport, in candles.
  double _visible = 80;
  double _rightOffset = 0; // candles scrolled back from the newest
  double _scaleStartVisible = 80;
  Offset? _crosshair;

  @override
  void initState() {
    super.initState();
    _load(initial: true);
    if (!AppConfig.useMockData && !AppConfig.disableMt5Bridge) {
      final ticks = TickStreamService();
      _ticks = ticks;
      _tickSub = ticks.connect(symbol: AppConfig.brokerSymbol).listen(_onTick);
      _connSub = ticks.connectionStatus.listen((c) => setState(() => _tickConnected = c));
      ConnectionStatusService.instance.startHealthPolling();
      _restoredSub = ConnectionStatusService.instance.bridgeRestored.listen((_) => _load());
    }
    _scheduleRefresh();
  }

  void _scheduleRefresh() {
    _refreshTimer?.cancel();
    // With live ticks the candles only need periodic reconciliation; without
    // them (TwelveData/Yahoo/mock) poll more gently to respect rate limits.
    final interval = _tickConnected == true ? const Duration(seconds: 30) : const Duration(seconds: 45);
    _refreshTimer = Timer.periodic(interval, (_) => _load());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _tickSub?.cancel();
    _connSub?.cancel();
    _restoredSub?.cancel();
    _ticks?.dispose();
    ConnectionStatusService.instance.stopHealthPolling();
    super.dispose();
  }

  Future<void> _load({bool initial = false}) async {
    if (_refreshing) return;
    _refreshing = true;
    final tf = _tf;
    if (initial) setState(() => _loading = true);
    try {
      final candles = await _data.getCandles(timeframeMinutes: tf, count: 300);
      if (!mounted || tf != _tf) return;
      setState(() {
        _candles = candles;
        _error = null;
        _loading = false;
        _lastRefresh = DateTime.now();
        _feed = AppConfig.useMockData ? null : ConnectionStatusService.instance.current;
      });
    } catch (e) {
      AppLogger.log('Live chart: candle load failed: $e');
      if (!mounted) return;
      setState(() {
        _error = 'Feed unavailable — showing last data';
        _loading = false;
        _feed = FeedSource.disconnected;
      });
    } finally {
      _refreshing = false;
    }
  }

  /// Applies a bridge tick to the forming candle (or opens the next one).
  /// Only when the chart itself is showing bridge data — mixing broker ticks
  /// into TwelveData/Yahoo candles would corrupt them.
  void _onTick(Tick tick) {
    if (!mounted) return;
    _lastTick = tick;
    if (_feed != FeedSource.liveBridge || _candles.isEmpty) {
      setState(() {});
      return;
    }
    final price = tick.bid;
    final last = _candles.last;
    final tfDuration = Duration(minutes: _tf);
    final updated = List<Candle>.of(_candles);
    if (!tick.time.isBefore(last.time.add(tfDuration))) {
      final tfMs = tfDuration.inMilliseconds;
      final openMs = (tick.time.millisecondsSinceEpoch ~/ tfMs) * tfMs;
      updated.add(Candle(
        time: DateTime.fromMillisecondsSinceEpoch(openMs, isUtc: true),
        open: price,
        high: price,
        low: price,
        close: price,
        volume: 1,
      ));
      if (updated.length > 400) updated.removeAt(0);
    } else {
      updated[updated.length - 1] = Candle(
        time: last.time,
        open: last.open,
        high: math.max(last.high, price),
        low: math.min(last.low, price),
        close: price,
        volume: last.volume + 1,
      );
    }
    setState(() => _candles = updated);
  }

  void _selectTf(int tf) {
    if (tf == _tf) return;
    setState(() {
      _tf = tf;
      _candles = const [];
      _rightOffset = 0;
    });
    _load(initial: true);
  }

  String _tfLabel(int tf) => switch (tf) {
        15 => '15M',
        60 => '1H',
        240 => '4H',
        _ => '${tf}m',
      };

  @override
  Widget build(BuildContext context) {
    final monitor = context.watch<SignalMonitor>();
    final openTrades = monitor.history.where((s) => s.outcome == TradeOutcome.open).toList();
    final livePrice = _candles.isNotEmpty ? _candles.last.close : null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Live Chart — ${AppConfig.symbol}'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), tooltip: 'Reload', onPressed: () => _load()),
        ],
      ),
      body: Column(
        children: [
          _header(livePrice, openTrades.length),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                for (final tf in _timeframes)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(_tfLabel(tf)),
                      selected: _tf == tf,
                      onSelected: (_) => _selectTf(tf),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: _loading && _candles.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : _candles.isEmpty
                    ? Center(child: Text(_error ?? 'No candles'))
                    : LayoutBuilder(
                        builder: (context, constraints) {
                          final chartWidth = constraints.maxWidth - _ChartPainter.priceAxisWidth;
                          return GestureDetector(
                            onScaleStart: (_) => _scaleStartVisible = _visible,
                            onScaleUpdate: (d) {
                              setState(() {
                                if (d.pointerCount > 1) {
                                  _visible = (_scaleStartVisible / d.scale).clamp(20.0, 300.0);
                                }
                                final candleWidth = chartWidth / _visible;
                                _rightOffset = (_rightOffset + d.focalPointDelta.dx / candleWidth)
                                    .clamp(0.0, math.max(0.0, _candles.length - 10.0));
                              });
                            },
                            onLongPressStart: (d) => setState(() => _crosshair = d.localPosition),
                            onLongPressMoveUpdate: (d) => setState(() => _crosshair = d.localPosition),
                            onLongPressEnd: (_) => setState(() => _crosshair = null),
                            onDoubleTap: () => setState(() {
                              _rightOffset = 0;
                              _visible = 80;
                            }),
                            child: CustomPaint(
                              size: Size(constraints.maxWidth, constraints.maxHeight),
                              painter: _ChartPainter(
                                candles: _candles,
                                visible: _visible,
                                rightOffset: _rightOffset,
                                openTrades: openTrades,
                                tick: _feed == FeedSource.liveBridge ? _lastTick : null,
                                crosshair: _crosshair,
                                timeframeMinutes: _tf,
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _header(double? livePrice, int openCount) {
    final feedColor = switch (_feed) {
      FeedSource.liveBridge => Colors.green,
      FeedSource.fallbackTwelveData => Colors.lightBlueAccent,
      FeedSource.fallbackYahoo => Colors.orange,
      FeedSource.disconnected => Colors.redAccent,
      null => Colors.grey,
    };
    final tick = _lastTick;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Wrap(
        spacing: 12,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            livePrice?.toStringAsFixed(2) ?? '—',
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFFD4AF37)),
          ),
          if (tick != null && _feed == FeedSource.liveBridge)
            Text('Bid ${tick.bid.toStringAsFixed(2)} · Ask ${tick.ask.toStringAsFixed(2)} · '
                'Spread ${(tick.spread / TradeSetup.dollarsPerPip).toStringAsFixed(1)}p'),
          _badge(AppConfig.useMockData ? 'MOCK DATA' : (_feed?.label ?? 'Connecting…'), feedColor),
          if (!AppConfig.useMockData)
            _badge(
              _tickConnected == true ? 'Ticks live' : 'Ticks offline',
              _tickConnected == true ? Colors.green : Colors.redAccent,
            ),
          if (openCount > 0) _badge('$openCount open trade${openCount > 1 ? "s" : ""}', Colors.amber),
          if (_error != null) _badge(_error!, Colors.redAccent),
          if (_lastRefresh != null)
            Text('Synced ${DateFormat('HH:mm:ss').format(_lastRefresh!)}',
                style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }

  Widget _badge(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(12)),
        child: Text(text, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
      );
}

class _ChartPainter extends CustomPainter {
  static const double priceAxisWidth = 64;
  static const double timeAxisHeight = 20;

  final List<Candle> candles;
  final double visible;
  final double rightOffset;
  final List<TradeSetup> openTrades;
  final Tick? tick;
  final Offset? crosshair;
  final int timeframeMinutes;

  _ChartPainter({
    required this.candles,
    required this.visible,
    required this.rightOffset,
    required this.openTrades,
    required this.tick,
    required this.crosshair,
    required this.timeframeMinutes,
  });

  static const _bull = Color(0xFF26A69A);
  static const _bear = Color(0xFFEF5350);
  static const _grid = Color(0x22FFFFFF);
  static const _axisText = Color(0xB3FFFFFF);

  @override
  void paint(Canvas canvas, Size size) {
    final chartW = size.width - priceAxisWidth;
    final chartH = size.height - timeAxisHeight;
    if (chartW <= 0 || chartH <= 0 || candles.isEmpty) return;

    final candleW = chartW / visible;
    final endIndex = (candles.length - 1 - rightOffset.floor()).clamp(0, candles.length - 1);
    final startIndex = math.max(0, endIndex - visible.ceil() + 1);
    final shown = candles.sublist(startIndex, endIndex + 1);

    var hi = shown.map((c) => c.high).reduce(math.max);
    var lo = shown.map((c) => c.low).reduce(math.min);
    // Keep open-trade levels that are near the visible range on screen.
    for (final t in openTrades) {
      for (final level in [t.entry, t.stopLoss, t.takeProfit]) {
        if (level < hi + (hi - lo) && level > lo - (hi - lo)) {
          hi = math.max(hi, level);
          lo = math.min(lo, level);
        }
      }
    }
    final pad = (hi - lo) * 0.06 + 0.01;
    hi += pad;
    lo -= pad;
    double y(double price) => chartH * (hi - price) / (hi - lo);
    double xOf(int index) => chartW - (endIndex - index + 0.5) * candleW;

    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, chartW, chartH));

    // Grid.
    final gridPaint = Paint()..color = _grid;
    for (var i = 0; i <= 5; i++) {
      final gy = chartH * i / 5;
      canvas.drawLine(Offset(0, gy), Offset(chartW, gy), gridPaint);
    }

    // Candles.
    final bodyW = math.max(1.0, candleW * 0.7);
    for (var i = startIndex; i <= endIndex; i++) {
      final c = candles[i];
      final x = xOf(i);
      final color = c.isBullish ? _bull : _bear;
      final paint = Paint()
        ..color = color
        ..strokeWidth = math.max(1.0, candleW * 0.1);
      canvas.drawLine(Offset(x, y(c.high)), Offset(x, y(c.low)), paint);
      final top = y(math.max(c.open, c.close));
      final bottom = y(math.min(c.open, c.close));
      canvas.drawRect(Rect.fromLTRB(x - bodyW / 2, top, x + bodyW / 2, math.max(bottom, top + 1)), paint);
    }

    // Open trades: Entry / SL / TP.
    for (final t in openTrades) {
      final startX = _xForTime(t.detectedAt, startIndex, endIndex, xOf, candleW) ?? 0;
      _levelLine(canvas, startX, chartW, y(t.entry), Colors.white70, dashed: true);
      _levelLine(canvas, startX, chartW, y(t.stopLoss), _bear);
      _levelLine(canvas, startX, chartW, y(t.takeProfit), _bull);
      _text(canvas, '${t.directionLabel} ${t.timeframeLabel}', Offset(math.min(startX + 4, chartW - 70), y(t.entry) - 14),
          Colors.white70, 10);
    }

    // Live price line (bid, when bridge ticks are applied).
    final live = candles.last.close;
    _levelLine(canvas, 0, chartW, y(live), const Color(0xFFD4AF37), dashed: true);
    if (tick != null) {
      _levelLine(canvas, 0, chartW, y(tick!.ask), const Color(0x66D4AF37), dashed: true);
    }

    // Crosshair.
    Candle? hovered;
    if (crosshair != null && crosshair!.dx < chartW) {
      final idx = (endIndex - ((chartW - crosshair!.dx) / candleW).floor()).clamp(startIndex, endIndex);
      hovered = candles[idx];
      final linePaint = Paint()..color = Colors.white38;
      canvas.drawLine(Offset(xOf(idx), 0), Offset(xOf(idx), chartH), linePaint);
      canvas.drawLine(Offset(0, crosshair!.dy), Offset(chartW, crosshair!.dy), linePaint);
    }
    canvas.restore();

    // Price axis.
    for (var i = 0; i <= 5; i++) {
      final price = hi - (hi - lo) * i / 5;
      _text(canvas, price.toStringAsFixed(2), Offset(chartW + 4, chartH * i / 5 - 6), _axisText, 10);
    }
    _priceTag(canvas, chartW, y(live), live, const Color(0xFFD4AF37));
    for (final t in openTrades) {
      _priceTag(canvas, chartW, y(t.stopLoss), t.stopLoss, _bear);
      _priceTag(canvas, chartW, y(t.takeProfit), t.takeProfit, _bull);
    }

    // Time axis (UTC → local).
    final fmt = timeframeMinutes >= 240 ? DateFormat('MM/dd HH:mm') : DateFormat('HH:mm');
    final step = math.max(1, (shown.length / 4).floor());
    for (var i = endIndex; i >= startIndex; i -= step) {
      final label = fmt.format(candles[i].time.toLocal());
      _text(canvas, label, Offset(xOf(i) - 16, chartH + 4), _axisText, 10);
    }

    if (hovered != null) {
      final h = hovered;
      _text(
        canvas,
        '${DateFormat('MM/dd HH:mm').format(h.time.toLocal())}  O ${h.open.toStringAsFixed(2)}  '
        'H ${h.high.toStringAsFixed(2)}  L ${h.low.toStringAsFixed(2)}  C ${h.close.toStringAsFixed(2)}',
        const Offset(6, 4),
        Colors.white,
        11,
        background: const Color(0xCC000000),
      );
    }
  }

  double? _xForTime(DateTime t, int startIndex, int endIndex, double Function(int) xOf, double candleW) {
    final tf = Duration(minutes: timeframeMinutes);
    for (var i = startIndex; i <= endIndex; i++) {
      final c = candles[i];
      if (!t.isBefore(c.time) && t.isBefore(c.time.add(tf))) return xOf(i) - candleW / 2;
    }
    if (candles[startIndex].time.isAfter(t)) return 0;
    return null;
  }

  void _levelLine(Canvas canvas, double x0, double x1, double yPos, Color color, {bool dashed = false}) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    if (!dashed) {
      canvas.drawLine(Offset(x0, yPos), Offset(x1, yPos), paint);
      return;
    }
    for (var x = x0; x < x1; x += 8) {
      canvas.drawLine(Offset(x, yPos), Offset(math.min(x + 4, x1), yPos), paint);
    }
  }

  void _priceTag(Canvas canvas, double x, double yPos, double price, Color color) {
    final rect = Rect.fromLTWH(x, yPos - 8, priceAxisWidth, 16);
    canvas.drawRect(rect, Paint()..color = color);
    _text(canvas, price.toStringAsFixed(2), Offset(x + 4, yPos - 7), Colors.black, 10);
  }

  void _text(Canvas canvas, String text, Offset at, Color color, double fontSize, {Color? background}) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: TextStyle(color: color, fontSize: fontSize)),
      textDirection: TextDirection.ltr,
    )..layout();
    if (background != null) {
      canvas.drawRect(Rect.fromLTWH(at.dx - 3, at.dy - 2, painter.width + 6, painter.height + 4), Paint()..color = background);
    }
    painter.paint(canvas, at);
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) => true;
}
