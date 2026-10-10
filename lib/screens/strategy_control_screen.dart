import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/emergency_service.dart';
import '../services/mt5_trading_service.dart';
import '../services/strategy_config_service.dart';

const Map<String, String> _engineLabels = {
  EngineIds.htfRetest: 'HTF Retest (Top-Down)',
  EngineIds.ict: 'ICT Liquidity Sweep',
  EngineIds.ici: 'ICI (Impulse-Correction-Impulse)',
  EngineIds.orb: 'Asia ORB (01:00 UTC Opening Range)',
  EngineIds.breakout: 'Breakout / Momentum',
  EngineIds.rangeBounce: 'Range Zone Bounce',
};

const Map<String, String> _pathLabels = {
  'mode.paused': 'Trading paused',
  'mode.auto_trade': 'Auto-trade mode',
  'account_limits.lot_mode': 'Lot mode',
  'account_limits.fixed_lot_size': 'Fixed lot size',
  'account_limits.risk_percent_per_trade': 'Risk per trade',
  'account_limits.max_daily_loss_percent': 'Max daily loss',
  'account_limits.on_daily_loss': 'When the daily limit is hit',
  'account_limits.max_spread_pips': 'Max spread',
  'account_limits.max_open_positions': 'Max open positions',
  'account_limits.max_lot': 'Max lot size',
  'account_limits.max_slippage_points': 'Max slippage',
  'account_limits.strict_min_lot_risk': 'Refuse an oversized minimum lot',
  'account_limits.entry_drift_chase_r': 'Late-approval tolerance',
  'trade_rules.default_rr': 'Default reward : risk',
  'trade_rules.one_active_trade': 'One active trade at a time',
  'filters.dxy.enabled': 'DXY correlation filter',
  'filters.news.enabled': 'News blackout filter',
  'filters.news.blackout_minutes': 'News blackout window',
  'filters.impulse.mode': 'Fast-impulse guard (Range Bounce)',
  'filters.impulse.consecutive': 'Impulse candles in a row',
  'filters.impulse.shock_atr': 'Shock candle size',
  'filters.impulse.min_hours': 'Restriction after a run',
  'filters.impulse.max_hours': 'Restriction after a shock',
  'filters.chaos.mode': 'Volatility / chaos filter (all engines)',
  'filters.chaos.range_mult': 'Candle range vs time-of-day median',
  'filters.chaos.spread_mult': 'Spread vs time-of-day median',
  'filters.chaos.pause_minutes': 'Pause length',
};

/// How the market-safety layers' modes read: shadow evaluates and logs but never blocks.
const Map<String, String> _layerModes = {'block': 'Block', 'shadow': 'Shadow (log only)', 'off': 'Off'};

const Set<String> _appliedPaths = {
  'mode.paused',
  'mode.auto_trade',
  'account_limits.lot_mode',
  'account_limits.fixed_lot_size',
  'account_limits.risk_percent_per_trade',
  'account_limits.max_daily_loss_percent',
  'account_limits.on_daily_loss',
  'account_limits.max_spread_pips',
  'account_limits.max_open_positions',
  'account_limits.max_lot',
  'account_limits.max_slippage_points',
  'account_limits.strict_min_lot_risk',
  'account_limits.entry_drift_chase_r',
  'trade_rules.one_active_trade',
  'trade_rules.default_rr',
  'filters.dxy.enabled',
  'filters.impulse.mode',
  'filters.impulse.consecutive',
  'filters.impulse.shock_atr',
  'filters.impulse.min_hours',
  'filters.impulse.max_hours',
  'filters.chaos.mode',
  'filters.chaos.range_mult',
  'filters.chaos.spread_mult',
  'filters.chaos.pause_minutes',
};

final RegExp _enginePath = RegExp(r'^engines\.(\w+)\.(\w+)$');
final RegExp _paramPath = RegExp(r'^engines\.(\w+)\.params\.(\w+)$');

enum _ParamKind { slider, intSlider, toggle, mode }

/// One editable engine threshold. Ranges come from the bridge's own hard bounds, so the screen
/// can never offer a value the bridge would refuse.
class _Param {
  const _Param(this.key, this.label, this.kind, {this.step = 1, this.suffix = '', this.hint});
  final String key;
  final String label;
  final _ParamKind kind;
  final double step;
  final String suffix;
  final String? hint;
}

const Map<String, List<_Param>> _engineParams = {
  EngineIds.htfRetest: [
    _Param('min_rr', 'Minimum reward : risk', _ParamKind.slider,
        step: 0.1, suffix: ' R', hint: 'A retest whose real target pays less than this is rejected.'),
  ],
  EngineIds.ict: [
    _Param('min_confluence_reversal', 'Minimum confluence (reversal entries)', _ParamKind.intSlider,
        hint: 'Counter-trend sweeps need a higher score than with-trend ones.'),
    _Param('sweep_mode', 'Sweep alignment rule', _ParamKind.mode,
        hint: 'A sweep reversal is only allowed with the 4H+1H bias, or — with no clear bias — at the edge of a real '
            'range. Shadow only logs what it would have blocked.'),
    _Param('sweep_range_lookback', 'Range window before the sweep', _ParamKind.intSlider, suffix: ' candles'),
    _Param('sweep_min_range_atr', 'Minimum range height (× ATR)', _ParamKind.slider, step: 0.1),
    _Param('sweep_boundary_atr', 'Boundary tolerance (× ATR)', _ParamKind.slider, step: 0.05),
    _Param('sweep_max_efficiency', 'Max trend efficiency of the range', _ParamKind.slider, step: 0.01),
  ],
  EngineIds.ici: [
    _Param('min_impulse_body_ratio', 'Impulse candle body / range', _ParamKind.slider, step: 0.01),
    _Param('min_consecutive_impulse', 'Consecutive impulse candles', _ParamKind.intSlider),
    _Param('min_rejection_wick_ratio', 'Rejection wick / range', _ParamKind.slider, step: 0.01),
    _Param('min_sl_pips', 'Stop-loss floor', _ParamKind.slider, step: 1, suffix: ' pips'),
  ],
  EngineIds.orb: [
    _Param('sl_pips_override', 'Fixed stop-loss', _ParamKind.slider,
        step: 5, suffix: ' pips', hint: '0 = dynamic (behind the opposite side of the range).'),
    _Param('tp_pips_override', 'Fixed take-profit', _ParamKind.slider,
        step: 10, suffix: ' pips', hint: '0 = dynamic (follows the R:R target, 1:2 unless the engine R:R is set).'),
  ],
  EngineIds.breakout: [
    _Param('min_body_atr', 'Min candle body (× ATR)', _ParamKind.slider, step: 0.05),
    _Param('max_body_atr', 'Max candle body (× ATR)', _ParamKind.slider,
        step: 0.1, hint: 'Rejects exhaustion candles that already ran too far.'),
    _Param('close_location', 'Close location in the candle', _ParamKind.slider, step: 0.01),
    _Param('min_range_expansion', 'Min range expansion', _ParamKind.slider, step: 0.05),
    _Param('max_entry_distance_atr', 'Max entry distance (× ATR)', _ParamKind.slider, step: 0.05),
    _Param('require_retest', 'Wait for a retest', _ParamKind.toggle,
        hint: 'Off = enter on the breakout candle itself.'),
    _Param('retest_lookback', 'Retest look-back', _ParamKind.intSlider, suffix: ' candles'),
    _Param('retest_tolerance_dollars', 'Retest tolerance', _ParamKind.slider, step: 0.1, suffix: ' \$'),
    _Param('failed_reversal', 'Trade failed breakouts (reversal)', _ParamKind.toggle),
    _Param('sl_atr', 'Stop-loss (× ATR)', _ParamKind.slider, step: 0.1),
    _Param('htf_mode', '4H bias filter', _ParamKind.mode),
  ],
  EngineIds.rangeBounce: [
    _Param('touch_dollars', 'Boundary touch distance', _ParamKind.slider, step: 0.1, suffix: ' \$'),
    _Param('min_wick_ratio', 'Rejection wick / range', _ParamKind.slider, step: 0.01),
    _Param('break_lookback', 'Break look-back', _ParamKind.intSlider, suffix: ' candles'),
    _Param('sl_atr', 'Stop-loss (× ATR)', _ParamKind.slider, step: 0.1),
    _Param('min_boundary_r', 'Min boundary reward (R)', _ParamKind.slider, step: 0.1),
    _Param('min_rr', 'Minimum reward : risk', _ParamKind.slider, step: 0.1, suffix: ' R'),
    _Param('zone_count', 'Zones evaluated', _ParamKind.intSlider),
    _Param('block_start_utc', 'No-entry window starts', _ParamKind.intSlider,
        suffix: ' h UTC',
        hint: 'OFF by default (24). Set it to 17 to stop Range Bounce entries from 17:00 UTC up to the end below.'),
    _Param('block_end_utc', 'No-entry window ends', _ParamKind.intSlider,
        suffix: ' h UTC', hint: 'A start at or after the end switches the rule off. 24 = midnight.'),
    _Param('max_atr_ratio', 'Hot-volatility limit', _ParamKind.slider,
        step: 0.05,
        suffix: ' × ATR',
        hint: 'No bounce while 15M ATR is above this multiple of its own 3-day median (1.2 = 20% hotter). 10 = off.'),
    _Param('max_fade_atr', 'Sharp-move limit (2 h)', _ParamKind.slider,
        step: 0.25,
        suffix: ' × ATR',
        hint: 'OFF by default (10). Lower it to stop fading a sharp move: no BUY after a fall, no SELL after a '
            'rally, bigger than this many ATR within the last 2 hours. Tested and found to cost money, so it ships off.'),
  ],
};

bool _isApplied(String path) {
  if (_appliedPaths.contains(path)) return true;
  final param = _paramPath.firstMatch(path);
  if (param != null) {
    return (_engineParams[param.group(1)] ?? const []).any((p) => p.key == param.group(2));
  }
  final field = _enginePath.firstMatch(path)?.group(2);
  return const {'enabled', 'dxy', 'max_spread_pips', 'rr', 'priority'}.contains(field);
}

String _labelFor(String path) {
  final label = _pathLabels[path];
  if (label != null) return label;
  final param = _paramPath.firstMatch(path);
  if (param != null) {
    final engine = _engineLabels[param.group(1)] ?? param.group(1)!;
    final name = (_engineParams[param.group(1)] ?? const <_Param>[])
        .where((p) => p.key == param.group(2))
        .map((p) => p.label)
        .firstOrNull;
    return '$engine · ${name ?? param.group(2)}';
  }
  final m = _enginePath.firstMatch(path);
  if (m != null) {
    final engine = _engineLabels[m.group(1)] ?? m.group(1)!;
    final field = const {
          'enabled': 'on/off',
          'dxy': 'DXY mode',
          'max_spread_pips': 'spread cap',
          'rr': 'R:R target',
          'priority': 'priority',
        }[m.group(2)] ??
        m.group(2)!;
    return '$engine · $field';
  }
  return path;
}

String _fmt(dynamic v) {
  if (v == null) return 'default';
  if (v is bool) return v ? 'on' : 'off';
  if (v is num) {
    return v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');
  }
  return '$v';
}

bool _same(dynamic a, dynamic b) {
  if (a is num && b is num) return (a - b).abs() < 1e-9;
  return a == b;
}

Map<String, dynamic> _nest(Map<String, dynamic> flat) {
  final root = <String, dynamic>{};
  flat.forEach((path, value) {
    final parts = path.split('.');
    var node = root;
    for (final part in parts.sublist(0, parts.length - 1)) {
      node = node.putIfAbsent(part, () => <String, dynamic>{}) as Map<String, dynamic>;
    }
    node[parts.last] = value;
  });
  return root;
}

/// Live control over the bridge's strategy config (strategy_config.py): per
/// engine switches, risk, spread and filters. Edits are staged locally and
/// sent together with "Save"; the bridge validates them against hard bounds
/// and asks for confirmation on anything that raises account risk. The one
/// exception is the Pause switch, which applies immediately.
class StrategyControlScreen extends StatefulWidget {
  const StrategyControlScreen({super.key, this.client});

  /// Injectable for tests.
  final http.Client? client;

  @override
  State<StrategyControlScreen> createState() => _StrategyControlScreenState();
}

class _StrategyControlScreenState extends State<StrategyControlScreen> {
  StrategyConfigView? _view;
  RiskStatus? _risk;
  bool _loading = true;
  bool _saving = false;

  /// Fields whose typed text is not acceptable (Save stays off) and a counter that rebuilds the text field
  /// after Discard / Save / reload so it shows the stored value again.
  final Set<String> _invalid = {};
  int _fieldEpoch = 0;
  final Map<String, dynamic> _draft = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  dynamic _server(String path) => _view?.valueAt(path);
  dynamic _value(String path) => _draft.containsKey(path) ? _draft[path] : _server(path);

  void _set(String path, dynamic value) {
    setState(() {
      if (_same(value, _server(path))) {
        _draft.remove(path);
      } else {
        _draft[path] = value;
      }
    });
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final view = await StrategyConfig.instance.fetchView(client: widget.client);
    final risk = view == null ? null : await Mt5TradingService(client: widget.client).getRiskStatus();
    if (!mounted) return;
    setState(() {
      _view = view;
      _risk = risk;
      _loading = false;
      _invalid.clear();
      _fieldEpoch++;
      _draft.removeWhere((path, value) => _same(value, view?.valueAt(path)));
    });
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _showError(String title, ConfigUpdateResult r) {
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(r.message),
              for (final e in r.errors) Padding(padding: const EdgeInsets.only(top: 6), child: Text('• $e')),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
      ),
    );
  }

  Future<bool?> _confirmRisk(List<String> risky, Map<String, dynamic> flat) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('risk-dialog'),
        icon: const Icon(Icons.warning_amber_rounded, color: Colors.orange),
        title: const Text('These changes increase risk'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('The bridge asks you to confirm before loosening these safety settings:'),
              const SizedBox(height: 10),
              for (final path in risky)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Text('• ${_labelFor(path)}: ${_fmt(_server(path))} → ${_fmt(flat[path])}',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            key: const Key('risk-confirm'),
            style: FilledButton.styleFrom(backgroundColor: Colors.orange.shade800),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Apply anyway'),
          ),
        ],
      ),
    );
  }

  Future<void> _overrideDailyLoss() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('override-dialog'),
        icon: const Icon(Icons.lock_open, color: Colors.orange),
        title: const Text('Unlock trading?'),
        content: const Text(
          'The daily loss limit protects the account. Unlocking gives a FRESH loss budget measured from the '
          'current equity, so the day\'s total loss can exceed the limit. It works once per day and is logged.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep locked')),
          FilledButton(
            key: const Key('override-confirm'),
            style: FilledButton.styleFrom(backgroundColor: Colors.orange.shade800),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Unlock'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    final result = await Mt5TradingService(client: widget.client).overrideDailyLoss();
    if (!mounted) return;
    _toast(result.message);
    await _load();
  }

  Future<void> _emergencyStop() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('emergency-dialog'),
        icon: const Icon(Icons.dangerous, color: Colors.red),
        title: const Text('Emergency stop'),
        content: const Text(
          'This will PAUSE all new trading and close EVERY open XAUUSD position on MT5 at market price. '
          'It cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            key: const Key('emergency-confirm'),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Stop & close all'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;

    setState(() => _saving = true);
    final result = await EmergencyService(client: widget.client).closeAllAndPause();
    if (!mounted) return;
    setState(() => _saving = false);
    await _load();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('emergency-result'),
        icon: Icon(result.allClear ? Icons.check_circle : Icons.warning_amber_rounded,
            color: result.allClear ? Colors.green : Colors.red),
        title: Text(result.allClear ? 'Stopped' : 'Needs attention'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(result.summary),
              for (final p in result.problems) Padding(padding: const EdgeInsets.only(top: 6), child: Text('• $p')),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
      ),
    );
  }

  Future<void> _save(Map<String, dynamic> flat, {bool confirm = false}) async {
    if (flat.isEmpty || _view == null) return;
    setState(() => _saving = true);
    final result = await StrategyConfig.instance.update(
      _nest(flat),
      baseRevision: _view!.revision,
      confirmRisk: confirm,
      client: widget.client,
    );
    if (!mounted) return;
    setState(() => _saving = false);

    if (result.ok) {
      setState(() {
        _view = result.view;
        flat.keys.forEach(_draft.remove);
        _invalid.clear();
        _fieldEpoch++;
      });
      _toast(result.warnings.isEmpty
          ? 'Saved — takes effect from the next scan (~30 s).'
          : 'Saved. Note: ${result.warnings.first}');
      return;
    }
    switch (result.code) {
      case 'confirmation_required':
        final yes = await _confirmRisk(result.risky, flat);
        if (yes == true && mounted) await _save(flat, confirm: true);
      case 'stale_revision':
        await _load();
        if (mounted) _toast('The config was changed elsewhere — reloaded. Review your edits and save again.');
      case 'risk_increase_rate_limited':
        await _showError('Too many risk increases', result);
      default:
        await _showError('Change rejected', result);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Strategy Control'),
        actions: [
          if (_view != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Center(child: Chip(label: Text('rev ${_view!.revision}'), visualDensity: VisualDensity.compact)),
            ),
          IconButton(
            key: const Key('reload-config'),
            tooltip: 'Reload from the bridge',
            icon: const Icon(Icons.refresh),
            onPressed: _loading || _saving ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _view == null
              ? _unavailable()
              : _content(context),
      bottomNavigationBar: _draft.isEmpty ? null : _saveBar(),
    );
  }

  Widget _unavailable() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48),
            const SizedBox(height: 12),
            Text('Bridge config unavailable', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
              'The control center edits the MT5 bridge\'s configuration, so it needs a live bridge '
              '(not mock or standalone mode). The app keeps running on its last known settings.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }

  Widget _saveBar() {
    final count = _draft.length;
    return SafeArea(
      child: Material(
        elevation: 8,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Expanded(child: Text('$count unsaved change${count == 1 ? '' : 's'}')),
              TextButton(
                key: const Key('discard-button'),
                onPressed: _saving
                    ? null
                    : () => setState(() {
                          _draft.clear();
                          _invalid.clear();
                          _fieldEpoch++;
                        }),
                child: const Text('Discard'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const Key('save-button'),
                onPressed: _saving || _hasInvalidInput ? null : () => _save(Map<String, dynamic>.of(_draft)),
                child: _saving
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _content(BuildContext context) {
    final view = _view!;
    final engines = (view.config['engines'] as Map?)?.keys.cast<String>().toList() ?? <String>[];
    engines.sort((a, b) =>
        ((_value('engines.$a.priority') as num?) ?? 99).compareTo((_value('engines.$b.priority') as num?) ?? 99));
    final paused = _server('mode.paused') == true;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        if (view.fingerprintMismatch) _fingerprintBanner(),
        Card(
          color: paused ? Colors.amber.withValues(alpha: 0.18) : null,
          child: SwitchListTile(
            key: const Key('pause-switch'),
            secondary: Icon(paused ? Icons.pause_circle : Icons.play_circle_outline,
                color: paused ? Colors.amber.shade800 : null),
            title: Text(paused ? 'Trading is PAUSED' : 'Pause all new signals'),
            subtitle: const Text(
              'Applies immediately. Open trades keep being tracked; nothing new is generated or sent to MT5. '
              'Resuming asks for confirmation.',
            ),
            value: paused,
            onChanged: _saving ? null : (v) => _save({'mode.paused': v}),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: OutlinedButton.icon(
            key: const Key('emergency-stop'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.red,
              side: const BorderSide(color: Colors.red),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            icon: const Icon(Icons.dangerous),
            label: const Text('Emergency stop — pause & close all positions'),
            onPressed: _saving ? null : _emergencyStop,
          ),
        ),
        if (_risk != null && _risk!.available) _dailyLossCard(),
        _section('Execution'),
        _autoTradeMode(),
        _switchRow('trade_rules.one_active_trade', 'One active trade at a time',
            hint: 'While any trade is open, no engine is evaluated.'),
        _section('Risk & limits'),
        _lotMode(),
        _slider('account_limits.risk_percent_per_trade', 'Risk per trade', step: 0.05, suffix: ' %'),
        _slider('account_limits.max_daily_loss_percent', 'Max daily loss', step: 0.5, suffix: ' %'),
        _slider('trade_rules.default_rr', 'Default reward : risk', step: 0.1, suffix: ' R'),
        _enumRow('account_limits.on_daily_loss', 'When the daily limit is hit',
            const {'block': 'Block new trades', 'close_all': 'Close all positions'}),
        _slider('account_limits.max_spread_pips', 'Max spread', step: 1, suffix: ' pips'),
        _slider('account_limits.max_open_positions', 'Max open positions', step: 1, isInt: true),
        _slider('account_limits.max_lot', 'Max lot size', step: 0.1),
        _slider('account_limits.max_slippage_points', 'Max slippage', step: 1, suffix: ' pts', isInt: true),
        _slider('account_limits.entry_drift_chase_r', 'Late-approval tolerance',
            step: 0.05,
            suffix: ' R',
            hint: 'If the price has already run in the trade\'s direction when you approve, it is still taken up to '
                'this share of the stop distance (the reward must stay at least equal to the risk). '
                '0 = only the flat \$1.50 limit. A move against the trade always keeps the flat limit.'),
        _switchRow('account_limits.strict_min_lot_risk', 'Refuse a trade whose smallest lot risks too much',
            hint: 'Off: the smallest lot is always allowed, even when it risks more than your risk % (small accounts). '
                'On: such a trade is not opened.'),
        _section('Filters'),
        _switchRow('filters.dxy.enabled', 'DXY correlation filter',
            hint: 'BUY only while the dollar is weak, SELL only while it is strong.'),
        _switchRow('filters.news.enabled', 'News blackout filter'),
        _slider('filters.news.blackout_minutes', 'News blackout window', step: 5, suffix: ' min', isInt: true),
        _marketSafetyLayers(),
        _section('Engines'),
        for (final id in engines) _engineCard(id, engines),
        const SizedBox(height: 12),
        Text(
          'Limits shown are the bridge\'s hard bounds. Changes apply from the next scan (~30 s); '
          'trades already open keep the stop and target they were opened with.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  /// The market-dynamics safety layers (the third, the ICT sweep alignment, sits with the ICT engine's own
  /// thresholds). Hidden when the bridge is too old to know them.
  Widget _marketSafetyLayers() {
    if (_view!.valueAt('filters.impulse.mode') == null && _view!.valueAt('filters.chaos.mode') == null) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _section('Market safety layers'),
        Text(
          'Shadow evaluates and records what a layer WOULD have blocked, but never blocks — the trade still goes '
          'ahead and is tagged. Switch a layer to Block once the shadow record has proven it.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        _enumRow('filters.impulse.mode', 'Fast-impulse guard (Range Bounce)', _layerModes),
        _slider('filters.impulse.consecutive', 'Impulse candles in a row', step: 1, isInt: true),
        _slider('filters.impulse.shock_atr', 'Shock candle size', step: 0.1, suffix: ' × ATR'),
        _slider('filters.impulse.min_hours', 'Restriction after a run', step: 0.5, suffix: ' h'),
        _slider('filters.impulse.max_hours', 'Restriction after a shock', step: 0.5, suffix: ' h'),
        _enumRow('filters.chaos.mode', 'Volatility / chaos filter (all engines)', _layerModes),
        _slider('filters.chaos.range_mult', 'Candle range vs time-of-day median', step: 0.1, suffix: ' ×'),
        _slider('filters.chaos.spread_mult', 'Spread vs time-of-day median', step: 0.1, suffix: ' ×'),
        _slider('filters.chaos.pause_minutes', 'Pause length', step: 5, suffix: ' min', isInt: true),
      ],
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 6),
        child: Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
      );

  Widget _fingerprintBanner() {
    return Card(
      color: Colors.red.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Icon(Icons.swap_horiz, color: Colors.red),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'The connected MT5 account is different from the one this config was set up on '
                '(demo ↔ live?). Review every limit before trading.',
              ),
            ),
            TextButton(
              key: const Key('ack-account'),
              onPressed: () async {
                final view = await StrategyConfig.instance.acknowledgeAccount(client: widget.client);
                if (!mounted) return;
                if (view != null) setState(() => _view = view);
              },
              child: const Text('This is correct'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _appliedChip(String path) {
    if (_isApplied(path)) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Tooltip(
        message: 'Stored on the bridge, but not enforced yet.',
        child: Chip(
          label: const Text('not applied yet'),
          visualDensity: VisualDensity.compact,
          labelStyle: Theme.of(context).textTheme.labelSmall,
          padding: EdgeInsets.zero,
        ),
      ),
    );
  }

  Widget _switchRow(String path, String label, {String? hint, Key? key}) {
    final value = _value(path);
    if (value is! bool) return const SizedBox.shrink();
    final dirty = _draft.containsKey(path);
    return SwitchListTile(
      key: key ?? Key(path),
      contentPadding: EdgeInsets.zero,
      title: Row(children: [
        Flexible(child: Text(label, style: dirty ? const TextStyle(fontWeight: FontWeight.bold) : null)),
        _appliedChip(path),
      ]),
      subtitle: hint == null ? null : Text(hint),
      value: value,
      onChanged: _saving ? null : (v) => _set(path, v),
    );
  }

  Widget _slider(String path, String label,
      {required double step, String suffix = '', bool isInt = false, String? hint}) {
    final bound = _view!.bounds[path];
    final min = bound is Map ? (bound['min'] as num?)?.toDouble() : null;
    final max = bound is Map ? (bound['max'] as num?)?.toDouble() : null;
    final raw = _value(path);
    if (min == null || max == null || raw is! num) return const SizedBox.shrink();
    final value = raw.toDouble().clamp(min, max);
    final divisions = ((max - min) / step).round();
    final dirty = _draft.containsKey(path);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Flexible(child: Text(label, style: dirty ? const TextStyle(fontWeight: FontWeight.bold) : null)),
            _appliedChip(path),
            const Spacer(),
            Text('${_fmt(value)}$suffix', style: const TextStyle(fontWeight: FontWeight.w600)),
          ]),
          Slider(
            key: Key(path),
            value: value,
            min: min,
            max: max,
            divisions: divisions > 0 ? divisions : null,
            onChanged: _saving
                ? null
                : (v) {
                    final snapped = (v / step).round() * step;
                    _set(path, isInt ? snapped.round() : double.parse(snapped.toStringAsFixed(4)));
                  },
          ),
          if (hint != null) Text(hint, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }

  Widget _enumRow(String path, String label, Map<String, String> names) {
    final value = _value(path);
    final values = ((_view!.bounds[path] as Map?)?['values'] as List?)?.cast<String>();
    if (value is! String || values == null) return const SizedBox.shrink();
    final dirty = _draft.containsKey(path);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(children: [
        Expanded(child: Text(label, style: dirty ? const TextStyle(fontWeight: FontWeight.bold) : null)),
        DropdownButton<String>(
          key: Key(path),
          value: values.contains(value) ? value : null,
          items: [for (final v in values) DropdownMenuItem(value: v, child: Text(names[v] ?? v))],
          onChanged: _saving ? null : (v) => v == null ? null : _set(path, v),
        ),
      ]),
    );
  }

  Widget _dailyLossCard() {
    final risk = _risk!;
    final loss = risk.lossPercent ?? 0;
    final limit = risk.limitPercent;
    final used = limit > 0 ? (loss / limit).clamp(0.0, 1.0) : 0.0;
    final color = risk.locked ? Colors.red : (used >= 0.66 ? Colors.orange : Colors.green);
    String pct(double v) => '${v.toStringAsFixed(2)}%';
    final lossText = loss > 0 ? '−${pct(loss)}' : '+${pct(-loss)}';
    return Card(
      key: const Key('daily-loss-card'),
      color: risk.locked ? Colors.red.withValues(alpha: 0.10) : null,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(risk.locked ? Icons.lock : Icons.shield_outlined, color: color, size: 20),
              const SizedBox(width: 8),
              const Text('Daily loss', style: TextStyle(fontWeight: FontWeight.w600)),
              const Spacer(),
              Text('$lossText of ${pct(limit)} limit', style: TextStyle(color: color, fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: used, color: color, minHeight: 6),
            const SizedBox(height: 6),
            Text(
              'Equity ${_fmt(risk.equity)} · day started at ${_fmt(risk.baseline)}'
              '${risk.baselineSource == 'first_seen' ? ' (estimated)' : ''}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (risk.locked) ...[
              const SizedBox(height: 10),
              Text(
                'Trading is LOCKED until 00:00 UTC'
                '${risk.lockedLossPercent == null ? '' : ' (lost ${pct(risk.lockedLossPercent!)})'}. '
                '${risk.onBreach == 'close_all' ? 'Open positions are closed automatically.' : 'Open positions were left alone.'}',
                style: const TextStyle(color: Colors.red, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('daily-loss-override'),
                icon: const Icon(Icons.lock_open),
                label: Text(risk.canOverride ? 'Unlock (fresh loss budget)…' : 'Override already used today'),
                onPressed: risk.canOverride && !_saving ? _overrideDailyLoss : null,
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Save is held back while the fixed-lot box holds something the bridge would refuse.
  bool get _hasInvalidInput =>
      _value('account_limits.lot_mode') == 'fixed' &&
      (_invalid.isNotEmpty || _lotProblem('${_value('account_limits.fixed_lot_size')}') != null);

  /// The smallest and largest fixed lot the screen accepts: the bridge's hard bounds, narrowed by its min / max lot size.
  (double, double) get _lotRange {
    final bound = _view!.bounds['account_limits.fixed_lot_size'];
    final low = [
      (bound is Map ? (bound['min'] as num?)?.toDouble() : null) ?? 0.01,
      (_value('account_limits.min_lot') as num?)?.toDouble() ?? 0.01,
    ].reduce((a, b) => a > b ? a : b);
    final high = [
      (bound is Map ? (bound['max'] as num?)?.toDouble() : null) ?? 10.0,
      (_value('account_limits.max_lot') as num?)?.toDouble() ?? 10.0,
    ].reduce((a, b) => a < b ? a : b);
    return (low, high);
  }

  /// Why [text] is not an acceptable fixed lot, or null when it is.
  String? _lotProblem(String? text) {
    final (low, high) = _lotRange;
    final value = double.tryParse((text ?? '').trim().replaceAll(',', '.'));
    if (value == null) return 'Enter a number, for example 0.05';
    if (value < low - 1e-9) return 'The minimum is ${_fmt(low)} lot';
    if (value > high + 1e-9) return 'The maximum is ${_fmt(high)} lot (your max lot size)';
    if (((value / 0.01) - (value / 0.01).round()).abs() > 1e-6) return 'Use steps of 0.01';
    return null;
  }

  /// Dynamic risk % or a fixed lot. Hidden when the bridge is too old to know the setting.
  Widget _lotMode() {
    if (_view!.valueAt('account_limits.lot_mode') == null) return const SizedBox.shrink();
    final mode = (_value('account_limits.lot_mode') as String?) ?? 'dynamic';
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Flexible(child: Text('Lot size')),
            _appliedChip('account_limits.lot_mode'),
          ]),
          const SizedBox(height: 6),
          SegmentedButton<String>(
            key: const Key('lot-mode'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'dynamic', label: Text('Dynamic risk %')),
              ButtonSegment(value: 'fixed', label: Text('Fixed lot')),
            ],
            selected: {mode},
            onSelectionChanged: _saving
                ? null
                : (s) {
                    setState(() {
                      _invalid.clear();
                      _fieldEpoch++;
                    });
                    _set('account_limits.lot_mode', s.first);
                  },
          ),
          if (mode == 'fixed') _fixedLotField(),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              mode == 'fixed'
                  ? 'Every trade uses this lot, whatever the stop distance; "Risk per trade" below is not used. '
                      'The daily loss limit still comes first: a trade is refused when the account is locked, or when its '
                      'stop could take the day past the limit.'
                  : 'The lot is sized from "Risk per trade" and the stop distance, in your account currency.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  /// The lot typed in fixed mode. Valid values (inside the bridge's limits, in steps of 0.01) are staged like any
  /// other edit; anything else shows why and keeps Save off.
  Widget _fixedLotField() {
    const path = 'account_limits.fixed_lot_size';
    final (low, high) = _lotRange;

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: TextFormField(
        key: ValueKey('fixed-lot-$_fieldEpoch'),
        initialValue: _fmt(_value(path)),
        enabled: !_saving,
        autovalidateMode: AutovalidateMode.always,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: 'Fixed lot size',
          suffixText: 'lot',
          border: const OutlineInputBorder(),
          helperText: 'Between ${_fmt(low)} and ${_fmt(high)} lot, in steps of 0.01. '
              'Your broker may allow a narrower range; the bridge checks it again at every trade.',
          helperMaxLines: 3,
        ),
        validator: _lotProblem,
        onChanged: (text) {
          if (_lotProblem(text) != null) {
            setState(() => _invalid.add(path));
            return;
          }
          _invalid.remove(path);
          _set(path, double.parse(double.parse(text.trim().replaceAll(',', '.')).toStringAsFixed(2)));
        },
      ),
    );
  }

  Widget _autoTradeMode() {
    final value = (_value('mode.auto_trade') as String?) ?? 'off';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Auto-trade mode'),
        const SizedBox(height: 6),
        SegmentedButton<String>(
          key: const Key('auto-trade-mode'),
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 'off', label: Text('Off')),
            ButtonSegment(value: 'approval', label: Text('Approval')),
            ButtonSegment(value: 'auto', label: Text('Auto')),
          ],
          selected: {value},
          onSelectionChanged: _saving ? null : (s) => _set('mode.auto_trade', s.first),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            'Auto: the bridge trades signals by itself. Approval: every signal is sent to your Telegram with '
            'Approve / Reject buttons, and the bridge re-checks price and limits at the moment you approve '
            '(needs TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID in bridge/.env). '
            'The app follows this setting from the next scan.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }

  /// Swaps this engine's priority with its neighbour's. Priorities must stay a
  /// permutation of 1..6, so a move is always a swap of two values.
  void _movePriority(String id, int delta, List<String> order) {
    final index = order.indexOf(id);
    final other = index + delta;
    if (index < 0 || other < 0 || other >= order.length) return;
    final mine = _value('engines.$id.priority');
    final theirs = _value('engines.${order[other]}.priority');
    _set('engines.$id.priority', theirs);
    _set('engines.${order[other]}.priority', mine);
  }

  Widget _paramRow(String id, _Param p) {
    final path = 'engines.$id.params.${p.key}';
    switch (p.kind) {
      case _ParamKind.toggle:
        return _switchRow(path, p.label, hint: p.hint, key: Key('param-$id-${p.key}'));
      case _ParamKind.mode:
        return _enumRow(path, p.label,
            const {'block': 'block', 'score': 'score only', 'shadow': 'shadow (log only)', 'off': 'off'});
      case _ParamKind.slider:
      case _ParamKind.intSlider:
        return _slider(path, p.label,
            step: p.step, suffix: p.suffix, isInt: p.kind == _ParamKind.intSlider, hint: p.hint);
    }
  }

  Widget _paramsSection(String id) {
    final params = _engineParams[id] ?? const <_Param>[];
    if (params.isEmpty) return const SizedBox.shrink();
    final dirty = _draft.keys.any((p) => p.startsWith('engines.$id.params.'));
    return ExpansionTile(
      key: Key('engine-$id-params'),
      tilePadding: EdgeInsets.zero,
      shape: const Border(),
      collapsedShape: const Border(),
      title: Text(
        'Entry thresholds',
        style: TextStyle(fontWeight: dirty ? FontWeight.bold : FontWeight.w600),
      ),
      subtitle: const Text('How strict this engine is — applies from the next scan'),
      children: [for (final p in params) _paramRow(id, p)],
    );
  }

  Widget _engineCard(String id, List<String> order) {
    final base = 'engines.$id';
    final enabled = _value('$base.enabled') == true;
    final dxy = (_value('$base.dxy') as String?) ?? 'block';
    final spread = _value('$base.max_spread_pips');
    final rr = _value('$base.rr');
    final defaultRr = _value('trade_rules.default_rr');
    final position = order.indexOf(id);
    final globalSpread = _value('account_limits.max_spread_pips');
    final dirty = _draft.keys.any((p) => p.startsWith('$base.'));
    final modes =
        ((_view!.bounds['$base.dxy'] as Map?)?['values'] as List?)?.cast<String>() ?? const ['block', 'off', 'exempt'];
    final allowedModes = modes.where((m) => id == EngineIds.breakout || m != 'score').toList();

    return Card(
      child: ExpansionTile(
        key: Key('engine-$id'),
        shape: const Border(),
        collapsedShape: const Border(),
        title: Text(
          _engineLabels[id] ?? id,
          style: TextStyle(fontWeight: dirty ? FontWeight.bold : FontWeight.w600),
        ),
        subtitle: Text(
          enabled
              ? 'Priority ${_fmt(_value('$base.priority'))} · DXY ${dxy == 'exempt' ? 'exempt' : dxy}'
                  '${rr is num ? ' · R:R ${_fmt(rr)}' : ''}'
                  '${spread is num ? ' · spread ≤ ${_fmt(spread)}' : ''}'
              : 'OFF — never evaluated, holds no cooldowns',
        ),
        trailing: Switch(
          key: Key('engine-$id-enabled'),
          value: enabled,
          onChanged: _saving ? null : (v) => _set('$base.enabled', v),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          Row(
            children: [
              Expanded(
                  child: Text(
                      'Priority ${_fmt(_value('$base.priority'))} of ${order.length} (1 wins when several fire at once)')),
              IconButton(
                key: Key('engine-$id-up'),
                tooltip: 'Higher priority',
                icon: const Icon(Icons.arrow_upward),
                onPressed: _saving || position <= 0 ? null : () => _movePriority(id, -1, order),
              ),
              IconButton(
                key: Key('engine-$id-down'),
                tooltip: 'Lower priority',
                icon: const Icon(Icons.arrow_downward),
                onPressed: _saving || position >= order.length - 1 ? null : () => _movePriority(id, 1, order),
              ),
            ],
          ),
          Row(
            children: [
              const Expanded(child: Text('DXY filter for this engine')),
              DropdownButton<String>(
                key: Key('engine-$id-dxy'),
                value: allowedModes.contains(dxy) ? dxy : null,
                items: [for (final m in allowedModes) DropdownMenuItem(value: m, child: Text(m))],
                onChanged: _saving ? null : (m) => m == null ? null : _set('$base.dxy', m),
              ),
            ],
          ),
          SwitchListTile(
            key: Key('engine-$id-own-rr'),
            contentPadding: EdgeInsets.zero,
            title: Text('Own R:R target${rr == null ? ' (using default ${_fmt(defaultRr)})' : ''}'),
            value: rr is num,
            onChanged:
                _saving ? null : (on) => _set('$base.rr', on ? (defaultRr is num ? defaultRr.toDouble() : 1.8) : null),
          ),
          if (rr is num) _slider('$base.rr', 'R:R target', step: 0.1, suffix: ' R'),
          SwitchListTile(
            key: Key('engine-$id-own-spread'),
            contentPadding: EdgeInsets.zero,
            title: Text('Own spread cap${spread == null ? ' (using global ${_fmt(globalSpread)})' : ''}'),
            value: spread is num,
            onChanged: _saving
                ? null
                : (on) =>
                    _set('$base.max_spread_pips', on ? (globalSpread is num ? globalSpread.toDouble() : 30.0) : null),
          ),
          if (spread is num) _slider('$base.max_spread_pips', 'Spread cap', step: 1, suffix: ' pips'),
          _paramsSection(id),
        ],
      ),
    );
  }
}
