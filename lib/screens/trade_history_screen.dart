import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/pivot.dart';
import '../models/trade_setup.dart';
import '../services/signal_monitor.dart';

class _StrategyStats {
  final int total;
  final int wins;
  final int losses;
  const _StrategyStats({required this.total, required this.wins, required this.losses});

  double? get winRate => (wins + losses) == 0 ? null : wins / (wins + losses) * 100;
}

class _Stats {
  final int total;
  final int open;
  final int wins;
  final int losses;
  final double netPips;
  final double avgRiskReward;
  final Map<StrategyFamily, _StrategyStats> byStrategy;

  const _Stats({
    required this.total,
    required this.open,
    required this.wins,
    required this.losses,
    required this.netPips,
    required this.avgRiskReward,
    required this.byStrategy,
  });

  double? get winRate => (wins + losses) == 0 ? null : wins / (wins + losses) * 100;

  static _Stats from(List<TradeSetup> history) {
    final closed = history.where((s) => s.outcome != TradeOutcome.open);
    final wins = closed.where((s) => s.outcome == TradeOutcome.win).length;
    final losses = closed.where((s) => s.outcome == TradeOutcome.loss).length;
    final netPips = closed.fold<double>(0, (sum, s) => sum + (s.pips ?? 0));
    final avgRR = history.isEmpty ? 0.0 : history.fold<double>(0, (sum, s) => sum + s.riskRewardRatio) / history.length;

    final byStrategy = <StrategyFamily, _StrategyStats>{};
    for (final family in StrategyFamily.values) {
      final trades = history.where((s) => s.setupType.strategyFamily == family);
      final familyClosed = trades.where((s) => s.outcome != TradeOutcome.open);
      byStrategy[family] = _StrategyStats(
        total: trades.length,
        wins: familyClosed.where((s) => s.outcome == TradeOutcome.win).length,
        losses: familyClosed.where((s) => s.outcome == TradeOutcome.loss).length,
      );
    }

    return _Stats(
      total: history.length,
      open: history.length - wins - losses,
      wins: wins,
      losses: losses,
      netPips: netPips,
      avgRiskReward: avgRR,
      byStrategy: byStrategy,
    );
  }
}

/// RECONSTRUCTED 2026-09-13 (new — Trade Performance Tracker & Analytics
/// Dashboard). Reads SignalMonitor.history (the SAME persisted signal
/// history every other screen already uses — see TradeSetup.
/// historyPrefsKey), so stats survive app restarts with no separate
/// storage of their own; "Net Pips" and per-trade P/L are computed via
/// TradeSetup.pips/pnlDollars, both derived from fields already persisted
/// (entry/stopLoss/takeProfit/closedPrice/direction), so nothing new needs
/// migrating.
class TradeHistoryScreen extends StatelessWidget {
  const TradeHistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final monitor = context.watch<SignalMonitor>();
    final history = monitor.history;
    final stats = _Stats.from(history);

    return Scaffold(
      appBar: AppBar(title: const Text('Trade Analytics')),
      body: history.isEmpty
          ? const Center(child: Text('No trades recorded yet.'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _SummaryGrid(stats: stats),
                const SizedBox(height: 20),
                Text('By Strategy', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                for (final family in StrategyFamily.values) _StrategyRow(family: family, stats: stats.byStrategy[family]!),
                const SizedBox(height: 20),
                Text('History (${history.length})', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                for (final setup in history) _TradeHistoryTile(setup: setup),
              ],
            ),
    );
  }
}

class _SummaryGrid extends StatelessWidget {
  final _Stats stats;
  const _SummaryGrid({required this.stats});

  @override
  Widget build(BuildContext context) {
    final winRateText = stats.winRate == null ? '—' : '${stats.winRate!.toStringAsFixed(1)}%';
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 2.2,
      children: [
        _StatCard(label: 'Total Trades', value: '${stats.total}'),
        _StatCard(label: 'Win Rate', value: winRateText),
        _StatCard(
          label: 'Net Pips',
          value: '${stats.netPips >= 0 ? "+" : ""}${stats.netPips.toStringAsFixed(1)}',
          color: stats.netPips >= 0 ? Colors.green : Colors.red,
        ),
        _StatCard(label: 'Avg R:R', value: '1:${stats.avgRiskReward.toStringAsFixed(1)}'),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;
  const _StatCard({required this.label, required this.value, this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 4),
          Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: color)),
        ],
      ),
    );
  }
}

class _StrategyRow extends StatelessWidget {
  final StrategyFamily family;
  final _StrategyStats stats;
  const _StrategyRow({required this.family, required this.stats});

  @override
  Widget build(BuildContext context) {
    final winRateText = stats.winRate == null ? '—' : '${stats.winRate!.toStringAsFixed(1)}%';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 90, child: Text(family.label, style: const TextStyle(fontWeight: FontWeight.w600))),
          Text('${stats.total} trades', style: Theme.of(context).textTheme.bodySmall),
          const Spacer(),
          Text('$winRateText win rate', style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _TradeHistoryTile extends StatelessWidget {
  final TradeSetup setup;
  const _TradeHistoryTile({required this.setup});

  @override
  Widget build(BuildContext context) {
    final (String badgeText, Color badgeColor) = switch (setup.outcome) {
      TradeOutcome.win => ('WIN', Colors.green),
      TradeOutcome.loss => ('LOSS', Colors.red),
      TradeOutcome.open => ('OPEN', Colors.orange),
    };

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(color: badgeColor.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(6)),
              child: Text(badgeText, style: TextStyle(color: badgeColor, fontWeight: FontWeight.bold, fontSize: 11)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(setup.setupLabel, style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                    'Entry ${setup.entry.toStringAsFixed(2)} → '
                    '${setup.closedPrice?.toStringAsFixed(2) ?? "…"} '
                    '${setup.pips != null ? "(${setup.pips! >= 0 ? "+" : ""}${setup.pips!.toStringAsFixed(1)} pips)" : ""} '
                    '· ${setup.timeframeLabel} · ${setup.setupType.strategyFamily.label} · '
                    '${DateFormat('MM/dd HH:mm').format(setup.detectedAt.toLocal())}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
