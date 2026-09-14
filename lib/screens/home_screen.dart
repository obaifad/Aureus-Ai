import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../config/app_config.dart';
import '../services/connection_status_service.dart';
import '../services/signal_monitor.dart';
import '../widgets/signal_card.dart';
import 'alerts_screen.dart';
import 'live_chart_screen.dart';
import 'settings_screen.dart';
import 'signal_detail_screen.dart';
import 'system_logs_screen.dart';
import 'trade_history_screen.dart';
import 'tradingview_chart_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final monitor = context.watch<SignalMonitor>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Aureus AI'),
        actions: [
          IconButton(
            tooltip: 'Manual Scan',
            icon: const Icon(Icons.refresh),
            onPressed: monitor.isChecking ? null : () => monitor.runManualScan(),
          ),
          PopupMenuButton<_MenuAction>(
            onSelected: (action) {
              final builder = switch (action) {
                _MenuAction.liveChart => (BuildContext c) => const LiveChartScreen(),
                _MenuAction.tradingView => (BuildContext c) => const TradingViewChartScreen(),
                _MenuAction.systemLogs => (BuildContext c) => const SystemLogsScreen(),
                _MenuAction.alerts => (BuildContext c) => const AlertsScreen(),
                _MenuAction.tradeHistory => (BuildContext c) => const TradeHistoryScreen(),
              };
              Navigator.of(context).push(MaterialPageRoute(builder: builder));
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: _MenuAction.liveChart,
                child: ListTile(leading: Icon(Icons.candlestick_chart_outlined), title: Text('Live Chart (signal feed)')),
              ),
              PopupMenuItem(
                value: _MenuAction.tradingView,
                child: ListTile(leading: Icon(Icons.show_chart_outlined), title: Text('TradingView (OANDA reference)')),
              ),
              PopupMenuItem(
                value: _MenuAction.tradeHistory,
                child: ListTile(leading: Icon(Icons.query_stats_outlined), title: Text('Trade Analytics')),
              ),
              PopupMenuItem(
                value: _MenuAction.systemLogs,
                child: ListTile(leading: Icon(Icons.terminal_outlined), title: Text('System Logs')),
              ),
              PopupMenuItem(
                value: _MenuAction.alerts,
                child: ListTile(leading: Icon(Icons.notifications_active_outlined), title: Text('Price Alerts')),
              ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          _StatusBar(monitor: monitor),
          Expanded(
            child: monitor.history.isEmpty
                ? _EmptyState(isRunning: monitor.isRunning)
                : ListView.builder(
                    padding: const EdgeInsets.only(top: 8, bottom: 24),
                    itemCount: monitor.history.length,
                    itemBuilder: (context, index) {
                      final setup = monitor.history[index];
                      return SignalCard(
                        setup: setup,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => SignalDetailScreen(setup: setup)),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => monitor.isRunning ? monitor.stop() : monitor.start(),
        icon: Icon(monitor.isRunning ? Icons.pause : Icons.play_arrow),
        label: Text(monitor.isRunning ? 'Pause' : 'Start Monitoring'),
        backgroundColor: monitor.isRunning ? Colors.orange : const Color(0xFFD4AF37),
      ),
    );
  }
}

enum _MenuAction { liveChart, tradingView, systemLogs, alerts, tradeHistory }

/// Running state, symbol/timeframe pills, a pulsing "live" dot while
/// monitoring is active, the last successful scan timestamp, the live
/// diagnostic status text, and — only in live (non-mock) mode — an MT5
/// Bridge connectivity indicator.
class _StatusBar extends StatefulWidget {
  final SignalMonitor monitor;
  const _StatusBar({required this.monitor});

  @override
  State<_StatusBar> createState() => _StatusBarState();
}

class _StatusBarState extends State<_StatusBar> with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(vsync: this, duration: const Duration(seconds: 1))..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final monitor = widget.monitor;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FadeTransition(
                      opacity: monitor.isRunning
                          ? Tween(begin: 0.3, end: 1.0).animate(_pulseController)
                          : const AlwaysStoppedAnimation(1.0),
                      child: _Pill(
                        icon: monitor.isRunning ? Icons.podcasts : Icons.pause_circle_outline,
                        label: monitor.isRunning ? 'Active' : 'Idle',
                        color: monitor.isRunning ? Colors.green : Colors.grey,
                      ),
                    ),
                    const SizedBox(width: 6),
                    const _Pill(icon: Icons.token_outlined, label: AppConfig.symbol, color: Color(0xFFD4AF37)),
                    const SizedBox(width: 6),
                    if (monitor.isRunning)
                      const _Pill(icon: Icons.bolt, label: '15M', color: Colors.amber),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: switch ((AppConfig.useMockData, AppConfig.disableMt5Bridge)) {
                    (true, _) => const Text('MOCK DATA', style: TextStyle(fontSize: 10, color: Colors.orange)),
                    (false, true) => const Text('STANDALONE', style: TextStyle(fontSize: 10, color: Colors.lightBlueAccent)),
                    (false, false) => const _BridgeStatusIndicator(),
                  },
                ),
              ),
            ],
          ),
          if (!AppConfig.useMockData) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                if (monitor.feed != null)
                  _Pill(
                    icon: Icons.cloud_outlined,
                    label: 'Feed: ${monitor.feed!.label}',
                    color: monitor.feed!.isSpot ? Colors.lightBlueAccent : Colors.orange,
                  ),
                if (monitor.tickConnected != null)
                  _Pill(
                    icon: monitor.tickConnected! ? Icons.sensors : Icons.sensors_off,
                    label: monitor.tickConnected! ? 'Ticks live' : 'Ticks offline',
                    color: monitor.tickConnected! ? Colors.green : Colors.redAccent,
                  ),
                if (monitor.livePrice != null)
                  _Pill(
                    icon: Icons.attach_money,
                    label: monitor.livePrice!.toStringAsFixed(2),
                    color: const Color(0xFFD4AF37),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 6),
          if (monitor.lastSuccessfulCheck != null)
            Text(
              'Last successful scan: ${DateFormat('HH:mm:ss').format(monitor.lastSuccessfulCheck!.toLocal())}',
              style: Theme.of(context).textTheme.bodySmall,
            )
          else if (monitor.lastCheck != null)
            Text(
              'Last check: ${DateFormat('HH:mm:ss').format(monitor.lastCheck!.toLocal())} (no successful scan yet)',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          const SizedBox(height: 4),
          Text(
            monitor.status,
            style: Theme.of(context).textTheme.bodySmall,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const _Pill({required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// Polls the MT5 bridge server's unauthenticated `/health` endpoint every
/// 10s and shows a green/red dot — only rendered when [AppConfig.
/// useMockData] is false, since mock mode has no bridge to check.
class _BridgeStatusIndicator extends StatefulWidget {
  const _BridgeStatusIndicator();

  @override
  State<_BridgeStatusIndicator> createState() => _BridgeStatusIndicatorState();
}

class _BridgeStatusIndicatorState extends State<_BridgeStatusIndicator> {
  bool? _connected;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _check();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _check());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    try {
      final uri = Uri.parse('${AppConfig.bridgeBaseUrl}/health');
      final response = await http.get(uri).timeout(const Duration(seconds: 4));
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      if (mounted) setState(() => _connected = body['connected'] == true);
    } catch (_) {
      if (mounted) setState(() => _connected = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _connected == true ? Colors.green : Colors.red;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text('MT5 Bridge', style: TextStyle(fontSize: 10, color: color)),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  final bool isRunning;
  const _EmptyState({required this.isRunning});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.auto_graph, size: 56, color: Color(0xFFD4AF37)),
            const SizedBox(height: 16),
            Text(
              isRunning
                  ? 'Monitoring XAUUSD for a 15M trendline × S/R confluence…'
                  : 'Press "Start Monitoring" to let Aureus AI watch XAUUSD for you.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
