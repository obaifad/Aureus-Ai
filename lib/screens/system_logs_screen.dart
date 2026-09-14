import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../services/app_logger.dart';

enum _LogFilter { all, triggers, warnings }

/// RECONSTRUCTED 2026-09-12 (the original file was lost — see chat for
/// context). Shows AppLogger's ring buffer live (via AppLogger.version),
/// newest line first, with Clear/Copy/Share actions and a quick filter
/// row.
class SystemLogsScreen extends StatefulWidget {
  const SystemLogsScreen({super.key});

  @override
  State<SystemLogsScreen> createState() => _SystemLogsScreenState();
}

class _SystemLogsScreenState extends State<SystemLogsScreen> {
  _LogFilter _filter = _LogFilter.all;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    // The background service writes to the shared log file from its own
    // isolate — poll the file so those lines appear live here too.
    AppLogger.refreshFromDisk();
    _refreshTimer = Timer.periodic(const Duration(seconds: 2), (_) => AppLogger.refreshFromDisk());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  List<String> _filtered(List<String> all) {
    switch (_filter) {
      case _LogFilter.all:
        return all;
      case _LogFilter.triggers:
        return all.where((l) => l.contains('✅') || l.contains('Fired') || l.contains('new signal')).toList();
      case _LogFilter.warnings:
        return all
            .where((l) =>
                l.contains('⚠️') ||
                l.contains('Market Closed') ||
                l.contains('rejected') ||
                l.contains('Error') ||
                l.contains('error') ||
                l.contains('failed') ||
                l.contains('dropped') ||
                l.contains('Paused') ||
                l.contains('stale') ||
                l.contains('Stale'))
            .toList();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: AppLogger.version,
      builder: (context, _, __) {
        final lines = _filtered(AppLogger.entries).reversed.toList();
        final joined = lines.join('\n');

        return Scaffold(
          appBar: AppBar(
            title: const Text('System Logs'),
            actions: [
              IconButton(
                tooltip: 'Copy to Clipboard',
                icon: const Icon(Icons.copy_outlined),
                onPressed: lines.isEmpty
                    ? null
                    : () {
                        Clipboard.setData(ClipboardData(text: joined));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Logs copied to clipboard')),
                        );
                      },
              ),
              IconButton(
                tooltip: 'Share / Export',
                icon: const Icon(Icons.share_outlined),
                onPressed: lines.isEmpty ? null : () => Share.share(joined, subject: 'Aureus AI System Logs'),
              ),
              IconButton(
                tooltip: 'Clear Logs',
                icon: const Icon(Icons.delete_outline),
                onPressed: AppLogger.entries.isEmpty ? null : () => AppLogger.clear(),
              ),
            ],
          ),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('All'),
                      selected: _filter == _LogFilter.all,
                      onSelected: (_) => setState(() => _filter = _LogFilter.all),
                    ),
                    ChoiceChip(
                      label: const Text('Triggers / Signals'),
                      selected: _filter == _LogFilter.triggers,
                      onSelected: (_) => setState(() => _filter = _LogFilter.triggers),
                    ),
                    ChoiceChip(
                      label: const Text('Warnings / Market Closed'),
                      selected: _filter == _LogFilter.warnings,
                      onSelected: (_) => setState(() => _filter = _LogFilter.warnings),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: lines.isEmpty
                    ? const Center(child: Text('No log entries yet.'))
                    : ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: lines.length,
                        itemBuilder: (context, index) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Text(
                            lines[index],
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                          ),
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}
