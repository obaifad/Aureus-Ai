import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/pivot.dart';
import '../models/trade_setup.dart';

class SignalDetailScreen extends StatelessWidget {
  final TradeSetup setup;
  const SignalDetailScreen({super.key, required this.setup});

  @override
  Widget build(BuildContext context) {
    final isBuy = setup.direction == TradeDirection.buy;
    final accent = isBuy ? const Color(0xFF16A34A) : const Color(0xFFDC2626);

    return Scaffold(
      appBar: AppBar(title: Text('${setup.symbol} ${setup.directionLabel} Signal')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Center(
            child: Text(
              '${setup.emoji} ${setup.directionLabel} ${setup.symbol}',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: accent),
            ),
          ),
          const SizedBox(height: 6),
          Center(
            child: Text(
              DateFormat('EEE d MMM, HH:mm').format(setup.detectedAt.toLocal()),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const SizedBox(height: 24),
          _row(context, '⏰ Timeframe', setup.timeframeLabel),
          _row(context, '🎯 Entry', '\$${setup.entry.toStringAsFixed(2)}'),
          _row(context, '🛑 Stop Loss', '\$${setup.stopLoss.toStringAsFixed(2)}'),
          _row(context, '🟢 Take Profit', '\$${setup.takeProfit.toStringAsFixed(2)}'),
          _row(context, '📐 Risk : Reward', '1 : ${setup.riskRewardRatio.toStringAsFixed(1)}'),
          _row(context, '🕯️ Confirmation Pattern', setup.pattern.name),
          const SizedBox(height: 20),
          Text('💡 AI Reason', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(setup.aiReason),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
          Text(value, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}
