import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:provider/provider.dart';

import '../config/app_config.dart';
import '../services/connection_status_service.dart';
import '../services/signal_monitor.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  String _pollLabel(Duration d) => d.inSeconds < 60 ? '${d.inSeconds} s' : '${d.inMinutes} min';

  String _hhmm(int minutesSinceMidnightUtc) =>
      '${(minutesSinceMidnightUtc ~/ 60).toString().padLeft(2, '0')}:'
      '${(minutesSinceMidnightUtc % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final monitor = context.watch<SignalMonitor>();
    final feed = monitor.feed;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionTitle(context, 'Data Source'),
          _infoTile('Mode', switch ((AppConfig.useMockData, AppConfig.disableMt5Bridge)) {
            (true, _) => 'Mock (simulated candles)',
            (false, true) => 'Standalone (TwelveData/Yahoo only — no MT5 bridge)',
            (false, false) => 'Live (MT5 bridge + failover)',
          }),
          if (!AppConfig.useMockData && AppConfig.disableMt5Bridge)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                'DISABLE_MT5_BRIDGE is set — this device never attempts the bridge/tick '
                'stream, so signals rely solely on the ~30s TwelveData/Yahoo poll (no '
                'sub-second tick fast path). Useful for a device with no path to the '
                'bridge PC; remove the flag to re-enable it.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (!AppConfig.useMockData && !AppConfig.disableMt5Bridge) ...[
            _infoTile('Bridge URL', AppConfig.bridgeBaseUrl),
            _infoTile('Bridge API key', AppConfig.bridgeApiKey.isEmpty ? 'Not set' : 'Configured ✓'),
            _infoTile(
              'Tick stream',
              switch (monitor.tickConnected) {
                true => 'Connected',
                false => 'Disconnected',
                null => 'Not running',
              },
            ),
          ],
          if (!AppConfig.useMockData) ...[
            _infoTile('Current feed', feed?.label ?? 'Unknown (no scan yet)'),
            _infoTile('TwelveData key', AppConfig.twelveDataApiKey.isEmpty ? 'Not set' : 'Configured ✓'),
            _infoTile('Signals on futures fallback', AppConfig.allowFuturesFallbackSignals ? 'Allowed' : 'Paused'),
          ],
          const SizedBox(height: 16),
          _sectionTitle(context, 'Strategy'),
          _infoTile('Symbol', AppConfig.symbol),
          _infoTile('Timeframes', '4H / 1H context · 15M execution (closed candles)'),
          _infoTile('Min Confluence Score', '${AppConfig.minConfluenceScore}/100'),
          _infoTile('Risk : Reward', '1 : ${AppConfig.riskRewardRatio.toStringAsFixed(1)}'),
          _infoTile('Min SL / TP', '${AppConfig.minStopLossPips.toStringAsFixed(0)} / '
              '${AppConfig.minTakeProfitPips.toStringAsFixed(0)} pips'),
          _infoTile('Poll interval', _pollLabel(AppConfig.pollInterval)),
          const SizedBox(height: 16),
          _sectionTitle(context, 'Engines'),
          _infoTile(
            'Trading mode',
            AppConfig.enableAutoTrading
                ? 'Auto-trading ON (orders are sent to MT5)'
                : 'Monitor only (signals, no orders)',
          ),
          _infoTile(
            'One Active Trade Limit',
            AppConfig.oneActiveTradeLimit ? 'On (no new signal while a trade is open)' : 'Off (positions may overlap)',
          ),
          _infoTile('HTF Retest (Top-Down)', 'Always on'),
          _infoTile('ICT', 'Always on'),
          _infoTile('ICI', 'Always on'),
          _infoTile('ORB', AppConfig.useOrb ? 'Enabled' : 'Disabled'),
          _infoTile('Breakout / Momentum', AppConfig.useBreakoutMomentum ? 'Enabled' : 'Disabled'),
          _infoTile('Range Bounce', AppConfig.enableRangingBounceMode ? 'Enabled' : 'Disabled'),
          const SizedBox(height: 16),
          _sectionTitle(context, 'Opening Range Breakout'),
          _infoTile('ORB strategy', AppConfig.useOrb ? 'Enabled' : 'Disabled'),
          if (AppConfig.useOrb) ...[
            _infoTile(
              'Sessions',
              [
                if (AppConfig.orbLondonEnabled) 'London',
                if (AppConfig.orbNewYorkEnabled) 'New York',
              ].join(', '),
            ),
            _infoTile('Retest mode', 'Required'),
            _infoTile(
              'Stop Loss',
              AppConfig.orbStopLossPipsOverride > 0
                  ? '${AppConfig.orbStopLossPipsOverride.toStringAsFixed(0)} pips (fixed)'
                  : 'Dynamic (opposite range side)',
            ),
            _infoTile(
              'Take Profit',
              AppConfig.orbTakeProfitPipsOverride > 0
                  ? '${AppConfig.orbTakeProfitPipsOverride.toStringAsFixed(0)} pips (fixed)'
                  : '1 : ${AppConfig.riskRewardRatio.toStringAsFixed(1)} (standard R:R)',
            ),
          ],
          const SizedBox(height: 16),
          _sectionTitle(context, 'Breakout / Momentum'),
          _infoTile('Breakout strategy', AppConfig.useBreakoutMomentum ? 'Enabled' : 'Disabled'),
          if (AppConfig.useBreakoutMomentum) ...[
            _infoTile('Level sources', 'Previous Session, Opening Range, PDH/PDL, HTF S/R'),
            _infoTile(
              'Opening Range window',
              '${_hhmm(AppConfig.breakoutOpeningRangeStartUtcMinutes)}–'
                  '${_hhmm(AppConfig.breakoutOpeningRangeEndUtcMinutes)} UTC',
            ),
            _infoTile(
              'Body/ATR(14) band',
              '${AppConfig.breakoutMinBodyToAtrRatio.toStringAsFixed(1)}x – '
                  '${AppConfig.breakoutMaxBodyToAtrRatio.toStringAsFixed(1)}x',
            ),
            _infoTile(
              'Close-location filter',
              'Top/bottom ${((1 - AppConfig.breakoutCloseLocationThreshold) * 100).round()}%',
            ),
          ],
          const SizedBox(height: 16),
          _sectionTitle(context, 'Range Bounce'),
          _infoTile('Range Bounce strategy', AppConfig.enableRangingBounceMode ? 'Enabled' : 'Disabled'),
          if (AppConfig.enableRangingBounceMode) ...[
            _infoTile('Active when', 'No clear HTF bias (1H undefined or 1H/4H disagree)'),
            _infoTile('DXY filter', 'Exempt (not applied to this engine)'),
            _infoTile('Touch Proximity', '\$${AppConfig.zoneBounceTouchDollars.toStringAsFixed(2)} from the level'),
            _infoTile(
              'Min Wick Ratio',
              '${(AppConfig.zoneBounceMinWickRatio * 100).round()}% of candle range',
            ),
            _infoTile('Break Lookback Candles', '${AppConfig.zoneBounceBreakLookback} candles'),
            _infoTile(
              'Stop Loss ATR Margin',
              '${AppConfig.zoneBounceSlAtrMultiplier.toStringAsFixed(2)}x ATR(14) beyond the wick',
            ),
            _infoTile(
              'Min Boundary R:R',
              'Clip TP at range boundary only if ≥ ${AppConfig.zoneBounceMinBoundaryR.toStringAsFixed(1)}R away '
                  '(else 1 : ${AppConfig.riskRewardRatio.toStringAsFixed(1)})',
            ),
            _infoTile('Evaluated Zones Count', '${AppConfig.zoneBounceEvaluatedZoneCount} nearest zones'),
          ],
          const SizedBox(height: 16),
          _sectionTitle(context, 'DXY Correlation Filter'),
          _infoTile('Filter', AppConfig.useDxyFilter ? 'Enabled' : 'Disabled'),
          if (AppConfig.useDxyFilter) ...[
            _infoTile(
              'DXY symbol',
              AppConfig.dxySymbolName.isEmpty ? 'Auto-detect' : AppConfig.dxySymbolName,
            ),
            _infoTile(
              'Applies to',
              'HTF Retest, ICT, ICI, ORB (hard block); '
                  'Breakout via BREAKOUT_DXY_MODE=${AppConfig.breakoutDxyMode}',
            ),
            _infoTile('Exempt', 'Range Bounce (judged on range structure, not dollar bias)'),
          ],
          const SizedBox(height: 16),
          _sectionTitle(context, 'AI & Alerts'),
          _infoTile('Anthropic (app fallback)', AppConfig.anthropicApiKey.isEmpty ? 'Not set' : 'Configured ✓'),
          _infoTile('Telegram bot', AppConfig.telegramBotToken.isEmpty ? 'Not set' : 'Configured ✓'),
          if (!kIsWeb && Platform.isAndroid) ...[
            const SizedBox(height: 16),
            _sectionTitle(context, 'Background reliability'),
            FutureBuilder<bool>(
              future: FlutterForegroundTask.isIgnoringBatteryOptimizations,
              builder: (context, snapshot) {
                final ignoring = snapshot.data ?? false;
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Battery optimization'),
                  subtitle: Text(ignoring
                      ? 'Disabled for Aureus AI ✓'
                      : 'Enabled — Android may pause network access while the screen is off'),
                  trailing: ignoring
                      ? null
                      : TextButton(
                          onPressed: () => FlutterForegroundTask.requestIgnoreBatteryOptimization(),
                          child: const Text('Fix'),
                        ),
                );
              },
            ),
          ],
          const SizedBox(height: 24),
          Text(
            'Values are read from the .env file packaged with the app. Edit .env '
            '(see .env.example) and rebuild to change them. Note: everything in '
            '.env is bundled inside the APK — keep secret keys in bridge/.env.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String title) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      );

  Widget _infoTile(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                value,
                textAlign: TextAlign.end,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      );
}
