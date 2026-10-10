import 'package:flutter/material.dart';

import '../models/trade_setup.dart';
import '../services/signal_monitor.dart';

/// The one place a "Close Trade" tap goes through: asks first (a real MT5
/// position is closed at market, which can't be undone), then reports the
/// REAL outcome — a failed broker close is shown as a failure and the trade
/// stays open, instead of silently pretending it closed.
Future<void> confirmAndCloseTrade(BuildContext context, SignalMonitor monitor, TradeSetup setup) async {
  final ticket = setup.brokerTicket;
  final yes = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      key: const Key('close-trade-dialog'),
      title: const Text('Close this trade?'),
      content: Text(
        ticket != null
            ? 'This closes the REAL MT5 position #$ticket at the current market price. It cannot be undone.'
            : 'This is a signal-only trade (no MT5 position exists). It will be marked closed at the live price.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          key: const Key('close-trade-confirm'),
          style: FilledButton.styleFrom(backgroundColor: Colors.red),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Close trade'),
        ),
      ],
    ),
  );
  if (yes != true || !context.mounted) return;

  final messenger = ScaffoldMessenger.of(context);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(const SnackBar(content: Text('Closing…'), duration: Duration(seconds: 30)));

  final result = await monitor.closeTradeManually(setup.uid);

  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(result?.message ?? 'No live price yet — try again in a moment.'),
        backgroundColor: (result == null || !result.closed) ? Colors.red.shade700 : null,
        duration: Duration(seconds: (result?.closed ?? false) ? 4 : 8),
      ),
    );
}
