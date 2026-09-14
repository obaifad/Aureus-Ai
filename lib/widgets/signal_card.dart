import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/pivot.dart';
import '../models/trade_setup.dart';

class SignalCard extends StatelessWidget {
  final TradeSetup setup;
  final VoidCallback? onTap;

  const SignalCard({super.key, required this.setup, this.onTap});

  @override
  Widget build(BuildContext context) {
    final isBuy = setup.direction == TradeDirection.buy;
    final accent = isBuy ? const Color(0xFF16A34A) : const Color(0xFFDC2626);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: accent.withValues(alpha: 0.25)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${setup.emoji} ${setup.directionLabel} ${setup.symbol}',
                        style: TextStyle(color: accent, fontWeight: FontWeight.bold),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  const Spacer(),
                  if (setup.outcomeLabel != null)
                    Flexible(
                      child: Container(
                        margin: const EdgeInsets.only(right: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: (setup.outcome == TradeOutcome.win ? Colors.green : Colors.red).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          setup.outcomeLabel!,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: setup.outcome == TradeOutcome.win ? Colors.green : Colors.red,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  Text(
                    DateFormat('HH:mm').format(setup.detectedAt.toLocal()),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  _StatChip(label: 'Entry', value: setup.entry.toStringAsFixed(2)),
                  const SizedBox(width: 8),
                  _StatChip(label: 'SL', value: setup.stopLoss.toStringAsFixed(2), color: Colors.red),
                  const SizedBox(width: 8),
                  _StatChip(label: 'TP', value: setup.takeProfit.toStringAsFixed(2), color: Colors.green),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                '⏰ ${setup.timeframeLabel} · ${setup.setupType.label} · R:R 1:${setup.riskRewardRatio.toStringAsFixed(1)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (setup.confidenceBadge != null) ...[
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${setup.confidenceBadge} · ${setup.confluenceScore}/100',
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
              if (setup.outcome != TradeOutcome.open) ...[
                const SizedBox(height: 10),
                _OutcomeResultPanel(setup: setup),
              ],
              const SizedBox(height: 8),
              Text(
                setup.aiReason,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;

  const _StatChip({required this.label, required this.value, this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          children: [
            Text(label, style: Theme.of(context).textTheme.labelSmall),
            Text(
              value,
              style: TextStyle(fontWeight: FontWeight.bold, color: color),
            ),
          ],
        ),
      ),
    );
  }
}

/// The closed-trade result strip (2026-09-14, Dynamic Trade Outcome
/// feature) — net pips, realized R:R, and exit price/time. Only ever
/// built when [TradeSetup.outcome] is no longer [TradeOutcome.open]
/// (see the call site above), so every getter it reads ([pips],
/// [realizedRiskReward], [closedPrice], [closedAt]) is guaranteed
/// non-null here. Rebuilds automatically the instant SignalMonitor
/// (Provider/ChangeNotifier — see signal_monitor.dart) notices the
/// outcome change, whether that came from the ~30s candle sweep or the
/// sub-second tick fast path; no separate wiring needed in this widget.
class _OutcomeResultPanel extends StatelessWidget {
  final TradeSetup setup;
  const _OutcomeResultPanel({required this.setup});

  @override
  Widget build(BuildContext context) {
    final win = setup.outcome == TradeOutcome.win;
    final color = win ? Colors.green : Colors.red;
    final pips = setup.pips!;
    final rr = setup.realizedRiskReward!;
    final pipsText = '${pips >= 0 ? "+" : ""}${pips.toStringAsFixed(1)} Pips';
    final rrText = rr >= 0 ? 'R/R: 1:${rr.toStringAsFixed(1)}' : 'R/R: ${rr.toStringAsFixed(1)}';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(pipsText, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 16)),
              Text(rrText, style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 13)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Exit ${setup.closedPrice!.toStringAsFixed(2)} · ${DateFormat('MMM d, HH:mm').format(setup.closedAt!.toLocal())}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
