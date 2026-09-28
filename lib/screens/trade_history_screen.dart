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
  final double todayPips;
  final double weekPips;
  final double avgRiskReward;
  final Map<StrategyFamily, _StrategyStats> byStrategy;

  const _Stats({
    required this.total,
    required this.open,
    required this.wins,
    required this.losses,
    required this.netPips,
    required this.todayPips,
    required this.weekPips,
    required this.avgRiskReward,
    required this.byStrategy,
  });

  double? get winRate => (wins + losses) == 0 ? null : wins / (wins + losses) * 100;

  static _Stats from(List<TradeSetup> history) {
    final closed = history.where((s) => s.outcome != TradeOutcome.open);
    final wins = closed.where((s) => s.outcome == TradeOutcome.win).length;
    final losses = closed.where((s) => s.outcome == TradeOutcome.loss).length;
    final netPips = closed.fold<double>(0, (sum, s) => sum + (s.pips ?? 0));

    // Day/week boundaries anchored to local time so "today"/"this week"
    // match what the trader sees on their device clock, not UTC.
    final now = DateTime.now();
    final startOfToday = DateTime(now.year, now.month, now.day);
    final startOfWeek = startOfToday.subtract(Duration(days: now.weekday - 1));

    double pipsSince(DateTime cutoff) => closed
        .where((s) => s.closedAt != null && !s.closedAt!.toLocal().isBefore(cutoff))
        .fold<double>(0, (sum, s) => sum + (s.pips ?? 0));

    final todayPips = pipsSince(startOfToday);
    final weekPips = pipsSince(startOfWeek);

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
      todayPips: todayPips,
      weekPips: weekPips,
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
class TradeHistoryScreen extends StatefulWidget {
  const TradeHistoryScreen({super.key});

  @override
  State<TradeHistoryScreen> createState() => _TradeHistoryScreenState();
}

class _TradeHistoryScreenState extends State<TradeHistoryScreen> {
  // In-memory only (2026-09-18, explicit request): a display preference,
  // not trade data, so it doesn't need to survive alongside the persisted
  // signal history — resets to the detailed view on next app launch.
  bool _compactView = false;

  @override
  Widget build(BuildContext context) {
    // context.watch (not read) so the feed — and every stat derived from
    // it below — rebuilds the instant SignalMonitor's history changes,
    // whether that's a manual close here or an MT5 Bridge outcome sweep
    // landing from signal_checker.dart in the background.
    final monitor = context.watch<SignalMonitor>();
    final history = monitor.history;
    final stats = _Stats.from(history);

    return Scaffold(
      appBar: AppBar(title: const Text('Trade Analytics')),
      body: history.isEmpty
          ? const Center(child: Text('No trades recorded yet.'))
          : Column(
              children: [
                // Pinned outside the ListView (not a scroll child) so the
                // pip counters stay visible on screen no matter how far
                // the trader scrolls into the history list below.
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: _PipsSummaryBar(stats: stats),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                    children: [
                      _SummaryGrid(stats: stats),
                      const SizedBox(height: 20),
                      Text('By Strategy', style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      for (final family in StrategyFamily.values)
                        _StrategyRow(family: family, stats: stats.byStrategy[family]!),
                      const SizedBox(height: 20),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('History (${history.length})', style: Theme.of(context).textTheme.titleMedium),
                          _ViewToggle(
                            compact: _compactView,
                            onChanged: (value) => setState(() => _compactView = value),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      if (_compactView)
                        _CompactHistoryTable(history: history)
                      else
                        for (final setup in history) _TradeHistoryTile(setup: setup),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

/// Detailed/Compact segmented toggle shown next to the "History" heading.
class _ViewToggle extends StatelessWidget {
  final bool compact;
  final ValueChanged<bool> onChanged;
  const _ViewToggle({required this.compact, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<bool>(
      showSelectedIcon: false,
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
      segments: const [
        ButtonSegment(value: false, label: Text('Detailed'), icon: Icon(Icons.view_agenda_outlined, size: 16)),
        ButtonSegment(value: true, label: Text('Compact'), icon: Icon(Icons.view_list, size: 16)),
      ],
      selected: {compact},
      onSelectionChanged: (selection) => onChanged(selection.first),
    );
  }
}

/// Minimal list view (Entry / Exit / Timestamp / Strategy / Net Pips only)
/// — a header row plus one compact line per trade, for scanning the whole
/// feed at a glance instead of the detailed, expandable cards.
class _CompactHistoryTable extends StatelessWidget {
  final List<TradeSetup> history;
  const _CompactHistoryTable({required this.history});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Expanded(flex: 3, child: _CompactHeaderCell('ENTRY → EXIT')),
                Expanded(flex: 3, child: _CompactHeaderCell('TIME')),
                Expanded(flex: 3, child: _CompactHeaderCell('STRATEGY')),
                Expanded(flex: 2, child: _CompactHeaderCell('NET PIPS', alignEnd: true)),
              ],
            ),
          ),
          const Divider(height: 1),
          for (final setup in history) _CompactHistoryRow(setup: setup),
        ],
      ),
    );
  }
}

class _CompactHeaderCell extends StatelessWidget {
  final String text;
  final bool alignEnd;
  const _CompactHeaderCell(this.text, {this.alignEnd = false});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      textAlign: alignEnd ? TextAlign.end : TextAlign.start,
      style: Theme.of(context)
          .textTheme
          .labelSmall
          ?.copyWith(fontWeight: FontWeight.bold, letterSpacing: 0.4),
    );
  }
}

class _CompactHistoryRow extends StatelessWidget {
  final TradeSetup setup;
  const _CompactHistoryRow({required this.setup});

  @override
  Widget build(BuildContext context) {
    final pips = setup.pips;
    final pipsColor = pips == null
        ? Theme.of(context).colorScheme.onSurfaceVariant
        : (pips >= 0 ? Colors.green : Colors.red);
    final pipsText = pips == null ? '…' : '${pips >= 0 ? "+" : ""}${pips.toStringAsFixed(1)}';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: Text(
              '${setup.effectiveEntry.toStringAsFixed(2)} → ${setup.closedPrice?.toStringAsFixed(2) ?? "…"}',
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              DateFormat('MM/dd HH:mm').format((setup.closedAt ?? setup.detectedAt).toLocal()),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(
            flex: 3,
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 4,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    setup.setupType.strategyFamily.label,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                Text(setup.timeframeLabel, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              pipsText,
              textAlign: TextAlign.end,
              style: TextStyle(fontWeight: FontWeight.bold, color: pipsColor, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

/// Top-of-screen pip counter bar: all-time, today, and this-week net pips
/// side by side so the trader sees performance at a glance without
/// scrolling into the strategy breakdown or history list below.
class _PipsSummaryBar extends StatelessWidget {
  final _Stats stats;
  const _PipsSummaryBar({required this.stats});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
            Theme.of(context).colorScheme.primary.withValues(alpha: 0.04),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.15)),
      ),
      child: Row(
        children: [
          Expanded(
            child: _PipCounter(label: "Today's Pips", pips: stats.todayPips),
          ),
          _VerticalDivider(),
          Expanded(
            child: _PipCounter(label: "This Week's Pips", pips: stats.weekPips),
          ),
          _VerticalDivider(),
          Expanded(
            child: _PipCounter(label: 'Total Pips', pips: stats.netPips, emphasize: true),
          ),
        ],
      ),
    );
  }
}

class _VerticalDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 36,
      margin: const EdgeInsets.symmetric(horizontal: 8),
      color: Theme.of(context).colorScheme.outlineVariant,
    );
  }
}

class _PipCounter extends StatelessWidget {
  final String label;
  final double pips;
  final bool emphasize;
  const _PipCounter({required this.label, required this.pips, this.emphasize = false});

  @override
  Widget build(BuildContext context) {
    final isPositive = pips >= 0;
    final color = pips == 0 ? Theme.of(context).colorScheme.onSurfaceVariant : (isPositive ? Colors.green : Colors.red);
    final text = '${isPositive ? "+" : ""}${pips.toStringAsFixed(1)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 4),
        Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: emphasize ? 24 : 18,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ],
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

class _TradeHistoryTile extends StatefulWidget {
  final TradeSetup setup;
  const _TradeHistoryTile({required this.setup});

  @override
  State<_TradeHistoryTile> createState() => _TradeHistoryTileState();
}

class _TradeHistoryTileState extends State<_TradeHistoryTile> {
  // Closed trades start expanded (2026-09-18, explicit request) so the
  // Why/Advice block is visible straight away instead of behind a tap —
  // still collapsible for anyone scanning a long history.
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final setup = widget.setup;
    final badgeText = switch (setup.outcome) {
      TradeOutcome.win => 'WIN',
      TradeOutcome.loss => 'LOSS',
      TradeOutcome.open => 'OPEN',
      TradeOutcome.manualClose => 'CLOSED',
    };
    // Colored by the actual realized pips sign, not the raw outcome
    // (2026-09-21, explicit request — "كل شيء موجب يكون أخضر"): a trade
    // that partial-closed for real profit and then scratched the
    // remainder at Break-Even reads "LOSS" mechanically but is net
    // POSITIVE, so the badge must be green regardless of that label.
    final badgeColor = setup.outcome == TradeOutcome.open ? Colors.orange : ((setup.pips ?? 0) >= 0 ? Colors.green : Colors.red);
    final hasAnalysis = setup.outcome != TradeOutcome.open;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        onTap: hasAnalysis ? () => setState(() => _expanded = !_expanded) : null,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
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
                          'Entry ${setup.effectiveEntry.toStringAsFixed(2)} → '
                          '${setup.closedPrice?.toStringAsFixed(2) ?? "…"} '
                          '${setup.pips != null ? "(${setup.pips! >= 0 ? "+" : ""}${setup.pips!.toStringAsFixed(1)} pips)" : ""} '
                          '· ${setup.timeframeLabel} · ${setup.setupType.strategyFamily.label} · '
                          '${DateFormat('MM/dd HH:mm').format(setup.detectedAt.toLocal())}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  if (hasAnalysis)
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 20,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                ],
              ),
              if (hasAnalysis && _expanded) ...[
                const SizedBox(height: 10),
                _PostTradeAnalysis(setup: setup),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Collapsible "why it won/lost" + actionable tip shown under a closed
/// trade's summary row — sourced from [TradeSetup.postMortemReason] /
/// [TradeSetup.postMortemAdvice], both computed instantly from fields
/// already on the setup.
class _PostTradeAnalysis extends StatelessWidget {
  final TradeSetup setup;
  const _PostTradeAnalysis({required this.setup});

  @override
  Widget build(BuildContext context) {
    final reason = setup.postMortemReason;
    final advice = setup.postMortemAdvice;
    if (reason == null && advice == null) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (reason != null) ...[
            _AnalysisRow(icon: Icons.query_stats, iconColor: Colors.blueGrey, label: 'Why it happened', text: reason),
          ],
          if (reason != null && advice != null) const SizedBox(height: 8),
          if (advice != null)
            _AnalysisRow(icon: Icons.lightbulb_outline, iconColor: Colors.amber.shade800, label: 'Advice', text: advice),
        ],
      ),
    );
  }
}

class _AnalysisRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final String text;
  const _AnalysisRow({required this.icon, required this.iconColor, required this.label, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: iconColor),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              Text(text, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ],
    );
  }
}
