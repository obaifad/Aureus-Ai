import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../models/pivot.dart';
import '../models/trade_setup.dart';
import '../services/signal_monitor.dart';

class SignalCard extends StatelessWidget {
  final TradeSetup setup;
  final VoidCallback? onTap;

  /// Manual Close (2026-09-17) — invoked by the red "Close Trade" button,
  /// only ever shown while [TradeSetup.outcome] is [TradeOutcome.open].
  final VoidCallback? onCloseTrade;

  const SignalCard({super.key, required this.setup, this.onTap, this.onCloseTrade});

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
                      child: Builder(builder: (context) {
                        // Colored by the ACTUAL realized pips sign (2026-09-21,
                        // explicit request — "كل شيء موجب يكون أخضر"), not the
                        // raw win/loss outcome: a trade that partial-closed for
                        // real profit and then scratched the remainder at
                        // Break-Even is net POSITIVE and must read green, even
                        // though its mechanical outcome is technically "loss".
                        final positive = (setup.pips ?? 0) >= 0;
                        final color = positive ? Colors.green : Colors.red;
                        return Container(
                          margin: const EdgeInsets.only(right: 8),
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            setup.outcomeLabel!,
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: color),
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      }),
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
                  _StatChip(
                    label: setup.actualFillPrice != null ? 'Entry (Fill)' : 'Entry',
                    value: setup.effectiveEntry.toStringAsFixed(2),
                  ),
                  const SizedBox(width: 8),
                  _StatChip(label: setup.breakEvenActive ? 'SL (BE)' : 'SL', value: setup.activeStopLoss.toStringAsFixed(2), color: Colors.red),
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
              ] else ...[
                const SizedBox(height: 10),
                _LivePipCounter(setup: setup),
                if (onCloseTrade != null) ...[
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: onCloseTrade,
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
                      child: const Text('Close Trade'),
                    ),
                  ),
                ],
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

/// Live Pip Counter (2026-09-21, explicit request — "عداد يمشي يبين فوق
/// الصفقة... يبين عدد البيبات بشكل مباشر"): shows an OPEN trade's floating
/// pips, updating on every tick from the bridge (see MonitorEngine._onTick
/// -> SignalMonitor.liveBid/liveAsk), not just the ~30s scan cycle. Wrapped
/// in its own [Consumer] so a tick only ever rebuilds this small strip —
/// not the whole card, and not the rest of the history list — even though
/// ticks can arrive several times a second while the market is active.
///
/// Priced the same way a real close would be (mirrors [TradeSetup.
/// evaluateOutcomeAtTick]): a BUY's floating P/L is read off the live BID
/// (what you'd actually sell at right now), a SELL's off the live ASK.
/// Falls back to [SignalMonitor.livePrice] (the slower ~30s candle-cycle
/// price, spread assumed zero) when no tick has arrived yet — mock mode,
/// Standalone/no-bridge mode, or before the tick stream connects — so the
/// counter still shows SOMETHING rather than staying blank indefinitely.
class _LivePipCounter extends StatelessWidget {
  final TradeSetup setup;
  const _LivePipCounter({required this.setup});

  @override
  Widget build(BuildContext context) {
    return Consumer<SignalMonitor>(
      builder: (context, monitor, _) {
        final bid = monitor.liveBid ?? monitor.livePrice;
        final ask = monitor.liveAsk ?? monitor.livePrice;
        if (bid == null || ask == null) {
          return Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Center(
              child: Text('Waiting for live price…', style: Theme.of(context).textTheme.bodySmall),
            ),
          );
        }

        final currentPrice = setup.direction == TradeDirection.buy ? bid : ask;
        // effectiveEntry — the broker's real fill once known, not the
        // theoretical signal price (see TradeSetup.actualFillPrice).
        final delta =
            setup.direction == TradeDirection.buy ? bid - setup.effectiveEntry : setup.effectiveEntry - ask;
        final pips = delta / TradeSetup.dollarsPerPip;
        final color = pips >= 0 ? Colors.green : Colors.red;
        final pipsText = '${pips >= 0 ? "+" : ""}${pips.toStringAsFixed(1)} pips';

        return AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withValues(alpha: 0.3)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(pips >= 0 ? Icons.trending_up : Icons.trending_down, size: 16, color: color),
                  const SizedBox(width: 6),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: Text(
                      pipsText,
                      key: ValueKey(pipsText),
                      style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                  ),
                ],
              ),
              Text(
                'Live \$${currentPrice.toStringAsFixed(2)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        );
      },
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
    final pips = setup.pips!;
    // Colored by the actual realized pips sign, not [TradeSetup.outcome]
    // (2026-09-21, explicit request) — see the matching note on the
    // outcome badge above for why the two can disagree.
    final color = pips >= 0 ? Colors.green : Colors.red;
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
