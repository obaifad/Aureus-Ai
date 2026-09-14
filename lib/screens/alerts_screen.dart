import 'package:flutter/material.dart';

import '../models/price_alert.dart';
import '../services/price_alert_service.dart';

/// RECONSTRUCTED 2026-09-12 (the original file was lost — see chat for
/// context). Manages manual XAUUSD price alerts backed by
/// PriceAlertService — the actual price-crossing check already runs every
/// SignalChecker.check() cycle (see signal_checker.dart's price-alert
/// piggyback on 15M candles); this screen is purely CRUD + on/off.
class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key});

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  final PriceAlertService _service = PriceAlertService();
  final TextEditingController _priceController = TextEditingController();
  bool _triggerAbove = true;
  List<PriceAlert> _alerts = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _priceController.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final alerts = await _service.getAlerts();
    if (!mounted) return;
    setState(() {
      _alerts = alerts;
      _loading = false;
    });
  }

  Future<void> _addAlert() async {
    final price = double.tryParse(_priceController.text.trim());
    if (price == null || price <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid target price')),
      );
      return;
    }
    await _service.addAlert(targetPrice: price, triggerAbove: _triggerAbove);
    _priceController.clear();
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Price Alerts')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _priceController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Target Price',
                      prefixText: '\$ ',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: DropdownButtonFormField<bool>(
                    value: _triggerAbove,
                    decoration: const InputDecoration(
                      labelText: 'Condition',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: const [
                      DropdownMenuItem(value: true, child: Text('Price Rises Above')),
                      DropdownMenuItem(value: false, child: Text('Price Drops Below')),
                    ],
                    onChanged: (v) => setState(() => _triggerAbove = v ?? true),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _addAlert,
                icon: const Icon(Icons.add_alert_outlined),
                label: const Text('Add Alert'),
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _alerts.isEmpty
                    ? const Center(child: Text('No price alerts yet.'))
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: _alerts.length,
                        itemBuilder: (context, index) {
                          final alert = _alerts[index];
                          final conditionLabel = alert.triggerAbove ? 'Rises above' : 'Drops below';
                          return ListTile(
                            leading: Icon(
                              alert.triggerAbove ? Icons.trending_up : Icons.trending_down,
                              color: alert.triggerAbove ? Colors.green : Colors.red,
                            ),
                            title: Text('\$${alert.targetPrice.toStringAsFixed(2)}'),
                            subtitle: Text(
                              alert.triggered ? '$conditionLabel • Already triggered' : conditionLabel,
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Switch(
                                  value: alert.enabled,
                                  onChanged: (v) async {
                                    await _service.setEnabled(alert.id, v);
                                    await _reload();
                                  },
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () async {
                                    await _service.removeAlert(alert.id);
                                    await _reload();
                                  },
                                ),
                              ],
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
