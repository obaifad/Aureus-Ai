import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import '../models/pivot.dart' show StrategyFamily;
import 'app_logger.dart';
import 'data_service.dart' show bridgeHeaders;

/// Engine identifiers used by the bridge's strategy_config.json.
class EngineIds {
  EngineIds._();
  static const htfRetest = 'htf_retest';
  static const ict = 'ict';
  static const ici = 'ici';
  static const orb = 'orb';
  static const breakout = 'breakout';
  static const rangeBounce = 'range_bounce';
  static const all = [htfRetest, ict, ici, orb, breakout, rangeBounce];

  static String forFamily(StrategyFamily family) => switch (family) {
        StrategyFamily.topDown => htfRetest,
        StrategyFamily.ict => ict,
        StrategyFamily.ici => ici,
        StrategyFamily.orb => orb,
        StrategyFamily.breakout => breakout,
        StrategyFamily.rangingBounce => rangeBounce,
      };
}

/// Filter identifiers under `filters.<id>` in the bridge config for the market-dynamics safety layers.
class FilterIds {
  FilterIds._();
  static const impulse = 'impulse';
  static const chaos = 'chaos';
}

/// What a market-dynamics safety layer does with a setup it would reject:
///  * [off]    not evaluated at all;
///  * [shadow] evaluated and RECORDED (log + the setup's shadow flags) but never blocks — the default,
///             so a new layer is verified against real trades before it can stop one;
///  * [block]  enforced.
enum GuardMode {
  off,
  shadow,
  block;

  /// Anything unknown or missing is [shadow], never [block]: a layer must not start rejecting trades
  /// because of a typo, an old bridge or no bridge at all.
  static GuardMode parse(String? raw) => switch (raw?.toLowerCase().trim()) {
        'off' => GuardMode.off,
        'block' => GuardMode.block,
        _ => GuardMode.shadow,
      };
}

/// An immutable view of the bridge's strategy config. Every accessor returns
/// null when the value is absent, so callers fall back to `.env`/code
/// defaults — an empty snapshot (bridge never reached) changes nothing.
class StrategyConfigSnapshot {
  final int revision;
  final Map<String, dynamic> _config;

  const StrategyConfigSnapshot(this.revision, this._config);

  static const StrategyConfigSnapshot empty = StrategyConfigSnapshot(0, <String, dynamic>{});

  /// Accepts the `GET /config` body (`{config, revision, ...}`).
  factory StrategyConfigSnapshot.fromResponse(Map<String, dynamic> body) {
    final config = (body['config'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
    final revision = (body['revision'] as num?)?.toInt() ?? (config['revision'] as num?)?.toInt() ?? 0;
    return StrategyConfigSnapshot(revision, config);
  }

  bool get isEmpty => revision == 0;

  dynamic _at(List<String> path) {
    dynamic node = _config;
    for (final key in path) {
      if (node is! Map) return null;
      node = node[key];
    }
    return node;
  }

  bool? _bool(List<String> path) => _at(path) is bool ? _at(path) as bool : null;
  double? _num(List<String> path) => _at(path) is num ? (_at(path) as num).toDouble() : null;
  String? _str(List<String> path) => _at(path) is String ? _at(path) as String : null;

  String? get updatedBy => _config['updated_by'] as String?;
  bool get paused => _bool(['mode', 'paused']) ?? false;
  String? get autoTradeMode => _str(['mode', 'auto_trade']);
  double? get riskPercentPerTrade => _num(['account_limits', 'risk_percent_per_trade']);

  /// `dynamic` (lot sized from the risk percentage) or `fixed` (every trade uses [fixedLotSize]);
  /// null when the bridge does not know the setting.
  String? get lotMode => _str(['account_limits', 'lot_mode']);
  double? get fixedLotSize => _num(['account_limits', 'fixed_lot_size']);
  double? get maxSpreadPips => _num(['account_limits', 'max_spread_pips']);
  bool? get oneActiveTrade => _bool(['trade_rules', 'one_active_trade']);

  /// Minutes an engine stays quiet after its proposal was rejected, expired or
  /// could not be traded.
  int get rejectCooldownMinutes => (_num(['trade_rules', 'reject_cooldown_minutes']) ?? 15).round();
  bool? get dxyFilterEnabled => _bool(['filters', 'dxy', 'enabled']);

  /// The high-impact news blackout (`filters.news`) — applied to every engine since 2026-10-09.
  bool? get newsFilterEnabled => _bool(['filters', 'news', 'enabled']);
  double? get newsBlackoutMinutes => _num(['filters', 'news', 'blackout_minutes']);

  /// off | shadow | block of a market-dynamics safety layer (`filters.<name>.mode`); null when absent.
  String? filterMode(String name) => _str(['filters', name, 'mode']);

  /// A numeric setting of a safety layer (`filters.<name>.<key>`); null when absent.
  double? filterNum(String name, String key) => _num(['filters', name, key]);

  bool? engineEnabled(String id) => _bool(['engines', id, 'enabled']);

  /// Reward-to-risk target of one engine, or null when it follows the default.
  double? engineRiskReward(String id) => _num(['engines', id, 'rr']);

  /// The default reward-to-risk target every engine without its own follows.
  double? get defaultRiskReward => _num(['trade_rules', 'default_rr']);

  /// Rank when several engines fire in the same scan: 1 wins.
  int? enginePriority(String id) => _num(['engines', id, 'priority'])?.round();

  /// block | score | off | exempt — null when the bridge has no opinion.
  String? engineDxyMode(String id) => _str(['engines', id, 'dxy']);

  /// Per-engine override of the global spread cap; null = use the global one.
  double? engineMaxSpreadPips(String id) => _num(['engines', id, 'max_spread_pips']);

  /// An engine's own threshold (`engines.<id>.params.<key>`); null when the bridge has no value.
  double? engineParamNum(String id, String key) => _num(['engines', id, 'params', key]);
  bool? engineParamBool(String id, String key) => _bool(['engines', id, 'params', key]);
  String? engineParamStr(String id, String key) => _str(['engines', id, 'params', key]);
}

/// What the control screen shows: the bridge's LIVE config (not the
/// cycle-boundary [StrategyConfigSnapshot]), its hard bounds, and meta.
class StrategyConfigView {
  final int revision;
  final Map<String, dynamic> config;
  final Map<String, dynamic> bounds;
  final Map<String, dynamic> meta;

  const StrategyConfigView({
    required this.revision,
    required this.config,
    required this.bounds,
    required this.meta,
  });

  factory StrategyConfigView.fromBody(Map<String, dynamic> body) => StrategyConfigView(
        revision: (body['revision'] as num?)?.toInt() ?? 0,
        config: (body['config'] as Map?)?.cast<String, dynamic>() ?? const {},
        bounds: (body['bounds'] as Map?)?.cast<String, dynamic>() ?? const {},
        meta: (body['meta'] as Map?)?.cast<String, dynamic>() ?? const {},
      );

  /// Value at a dotted path such as `engines.orb.enabled`.
  dynamic valueAt(String path) {
    dynamic node = config;
    for (final key in path.split('.')) {
      if (node is! Map) return null;
      node = node[key];
    }
    return node;
  }

  bool get fingerprintMismatch => meta['fingerprint_mismatch'] == true;
}

/// Outcome of POST /config/update. [code] mirrors the bridge's error code:
/// `confirmation_required` (428), `stale_revision` (409), `validation_failed`
/// / `invalid_patch` (400), `risk_increase_rate_limited` (429),
/// `unreachable` (bridge not reachable at all).
class ConfigUpdateResult {
  final bool ok;
  final String? code;
  final String message;
  final List<String> risky;
  final List<String> errors;
  final List<String> warnings;
  final StrategyConfigView? view;

  const ConfigUpdateResult({
    required this.ok,
    this.code,
    this.message = '',
    this.risky = const [],
    this.errors = const [],
    this.warnings = const [],
    this.view,
  });
}

/// Runtime strategy configuration, owned by the bridge (strategy_config.py).
///
/// Race-free by construction: a freshly fetched snapshot is parked in
/// [_pending] and only becomes [current] at [beginCycle], which
/// SignalChecker.check calls once at the top of every scan. So one scan
/// always sees ONE consistent configuration, however many awaits it spans,
/// and a change made from the UI takes effect on the next cycle.
///
/// Never blocks trading on the bridge: with no bridge (mock/standalone mode,
/// an outage) it keeps the last good snapshot from SharedPreferences, and
/// with none at all every AppConfig getter falls back to `.env` as before.
class StrategyConfig {
  StrategyConfig._();
  static final StrategyConfig instance = StrategyConfig._();

  static const _prefsKey = 'aureus_strategy_config_v1';
  static const _timeout = Duration(seconds: 4);

  StrategyConfigSnapshot _current = StrategyConfigSnapshot.empty;
  StrategyConfigSnapshot? _pending;
  String? _etag;
  Map<String, dynamic> _bounds = const {};
  Map<String, dynamic> _meta = const {};
  bool _cacheLoaded = false;
  bool _seedAttempted = false;
  bool _paramsSeedAttempted = false;
  bool _fetchFailureLogged = false;

  StrategyConfigSnapshot get current => _current;
  StrategyConfigSnapshot? get pending => _pending;

  /// Promotes a freshly fetched snapshot. Call exactly once per scan.
  StrategyConfigSnapshot beginCycle() {
    final next = _pending;
    if (next != null) {
      _current = next;
      _pending = null;
    }
    return _current;
  }

  /// Direct injection for tests and historical replays (BT_CONFIG).
  void setSnapshot(StrategyConfigSnapshot snapshot) {
    _current = snapshot;
    _pending = null;
    _cacheLoaded = true;
  }

  /// Test hook: forget everything, including the seed attempt.
  void resetForTesting() {
    _current = StrategyConfigSnapshot.empty;
    _pending = null;
    _etag = null;
    _bounds = const {};
    _meta = const {};
    _cacheLoaded = false;
    _seedAttempted = false;
    _paramsSeedAttempted = false;
    _fetchFailureLogged = false;
  }

  Future<void> loadCache() async {
    if (_cacheLoaded) return;
    _cacheLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final raw = prefs.getString(_prefsKey);
      if (raw == null) return;
      final snapshot = StrategyConfigSnapshot.fromResponse(jsonDecode(raw) as Map<String, dynamic>);
      if (!snapshot.isEmpty && _current.isEmpty) _current = snapshot;
    } catch (e) {
      AppLogger.log('StrategyConfig: ignoring unreadable cache ($e)');
    }
  }

  Future<void> _persist(Map<String, dynamic> body) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefsKey,
        jsonEncode({'revision': body['revision'], 'config': body['config']}),
      );
    } catch (e) {
      AppLogger.log('StrategyConfig: could not cache config ($e)');
    }
  }

  /// Pulls the latest config from the bridge (cheap: ETag -> 304 when
  /// unchanged). Never throws. A no-op in mock/standalone mode.
  Future<void> refresh({http.Client? client}) async {
    await loadCache();
    if (_bridgeUnavailable) return;

    final http.Client c = client ?? http.Client();
    try {
      final headers = {...bridgeHeaders(), if (_etag != null) 'If-None-Match': _etag!};
      final response = await c.get(Uri.parse('${AppConfig.bridgeBaseUrl}/config'), headers: headers).timeout(_timeout);
      if (response.statusCode == 304) return;
      if (response.statusCode != 200) {
        _logFailureOnce('bridge /config returned ${response.statusCode}');
        return;
      }
      _fetchFailureLogged = false;
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final snapshot = StrategyConfigSnapshot.fromResponse(body);
      await _accept(body, etag: response.headers['etag']);
      if (!_seedAttempted && snapshot.revision == 1 && snapshot.updatedBy == 'init') {
        _seedAttempted = true;
        await _seedFromEnv(c, snapshot);
      }
      if (!_paramsSeedAttempted) {
        _paramsSeedAttempted = true;
        await _seedParamsFromEnv(c, (_pending ?? _current).isEmpty ? snapshot : (_pending ?? _current));
      }
    } catch (e) {
      _logFailureOnce('bridge /config unreachable ($e)');
    } finally {
      if (client == null) c.close();
    }
  }

  /// Takes a bridge response body: remembers bounds/meta and parks a newer
  /// revision as pending (it only goes live at [beginCycle]).
  Future<void> _accept(Map<String, dynamic> body, {String? etag}) async {
    if (etag != null) _etag = etag;
    _bounds = (body['bounds'] as Map?)?.cast<String, dynamic>() ?? _bounds;
    _meta = (body['meta'] as Map?)?.cast<String, dynamic>() ?? _meta;
    final snapshot = StrategyConfigSnapshot.fromResponse(body);
    if (snapshot.revision != 0 && snapshot.revision != (_pending ?? _current).revision) {
      _pending = snapshot;
      await _persist(body);
      AppLogger.log('StrategyConfig: bridge config revision ${snapshot.revision} fetched '
          '(applies next scan, updated by ${snapshot.updatedBy})');
    }
  }

  bool get _bridgeUnavailable => AppConfig.useMockData || AppConfig.disableMt5Bridge;

  /// Fetches the LIVE config for the control screen. Null when the bridge
  /// can't be reached (or in mock/standalone mode).
  Future<StrategyConfigView?> fetchView({http.Client? client}) async {
    if (_bridgeUnavailable) return null;
    final http.Client c = client ?? http.Client();
    try {
      final response =
          await c.get(Uri.parse('${AppConfig.bridgeBaseUrl}/config'), headers: bridgeHeaders()).timeout(_timeout);
      if (response.statusCode != 200) return null;
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      await _accept(body, etag: response.headers['etag']);
      return StrategyConfigView.fromBody(body);
    } catch (e) {
      AppLogger.log('StrategyConfig: could not load the live config ($e)');
      return null;
    } finally {
      if (client == null) c.close();
    }
  }

  /// POST /config/update. [patch] is a nested partial config; [baseRevision]
  /// is the revision the caller edited from. Never throws.
  Future<ConfigUpdateResult> update(
    Map<String, dynamic> patch, {
    required int baseRevision,
    bool confirmRisk = false,
    http.Client? client,
  }) async {
    if (_bridgeUnavailable) {
      return const ConfigUpdateResult(ok: false, code: 'unreachable', message: 'The MT5 bridge is not connected.');
    }
    final http.Client c = client ?? http.Client();
    try {
      final response = await c
          .post(
            Uri.parse('${AppConfig.bridgeBaseUrl}/config/update'),
            headers: {...bridgeHeaders(), 'Content-Type': 'application/json'},
            body: jsonEncode({
              'base_revision': baseRevision,
              'patch': patch,
              'updated_by': 'app',
              'confirm_risk_increase': confirmRisk,
            }),
          )
          .timeout(_timeout);
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode == 200) {
        await _accept(body);
        return ConfigUpdateResult(
          ok: true,
          warnings: (body['warnings'] as List?)?.cast<String>() ?? const [],
          view: StrategyConfigView.fromBody(body),
        );
      }
      final detail = body['detail'];
      if (detail is Map) {
        return ConfigUpdateResult(
          ok: false,
          code: detail['code'] as String?,
          message: detail['message'] as String? ?? 'Rejected by the bridge (${response.statusCode}).',
          risky: (detail['risk_increasing'] as List?)?.cast<String>() ?? const [],
          errors: (detail['errors'] as List?)?.cast<String>() ?? const [],
        );
      }
      return ConfigUpdateResult(
        ok: false,
        code: 'http_${response.statusCode}',
        message: '${detail ?? 'Rejected by the bridge'} (${response.statusCode})',
      );
    } catch (e) {
      AppLogger.log('StrategyConfig: update failed ($e)');
      return ConfigUpdateResult(ok: false, code: 'unreachable', message: 'Could not reach the bridge: $e');
    } finally {
      if (client == null) c.close();
    }
  }

  /// POST /config/ack_account - accepts the connected MT5 account as the one
  /// this config was tuned for (clears the demo/live mismatch warning).
  Future<StrategyConfigView?> acknowledgeAccount({http.Client? client}) async {
    if (_bridgeUnavailable) return null;
    final http.Client c = client ?? http.Client();
    try {
      final response = await c
          .post(Uri.parse('${AppConfig.bridgeBaseUrl}/config/ack_account'), headers: bridgeHeaders())
          .timeout(_timeout);
      if (response.statusCode != 200) return null;
      return StrategyConfigView.fromBody(jsonDecode(response.body) as Map<String, dynamic>);
    } catch (e) {
      AppLogger.log('StrategyConfig: account acknowledge failed ($e)');
      return null;
    } finally {
      if (client == null) c.close();
    }
  }

  void _logFailureOnce(String message) {
    if (_fetchFailureLogged) return;
    _fetchFailureLogged = true;
    AppLogger.log('StrategyConfig: $message — keeping '
        '${_current.isEmpty ? ".env defaults" : "cached revision ${_current.revision}"}');
  }

  static const _paramsSeededKey = 'aureus_engine_params_seeded_v1';

  /// ONE-TIME move of the engines' thresholds from `.env` into the bridge. Engines now read their
  /// thresholds from the bridge config, so an install that tuned `.env` (for example
  /// BREAKOUT_FAILED_REVERSAL=true) keeps behaving the same instead of silently reverting to the
  /// built-in defaults. Only values that differ are sent, and after this the bridge is the owner:
  /// later edits on the control screen are never overwritten by `.env`.
  Future<void> _seedParamsFromEnv(http.Client c, StrategyConfigSnapshot base) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      if (prefs.getBool(_paramsSeededKey) == true) return;
      if (base.isEmpty) return;

      final patch = <String, dynamic>{};
      AppConfig.engineParamsFromEnv.forEach((engine, params) {
        params.forEach((key, envValue) {
          final bound = _bounds['engines.$engine.params.$key'];
          dynamic value = envValue;
          if (value is num && bound is Map) {
            final lo = bound['min'], hi = bound['max'];
            if (lo is num && value < lo) value = lo;
            if (hi is num && value > hi) value = hi;
          }
          if (value is String &&
              bound is Map &&
              bound['values'] is List &&
              !(bound['values'] as List).contains(value)) {
            return; // an unknown mode in .env: leave the bridge default alone
          }
          final current = base._at(['engines', engine, 'params', key]);
          final same = (current is num && value is num) ? (current - value).abs() < 1e-9 : current == value;
          if (current != null && same) return;
          ((patch[engine] ??= <String, dynamic>{}) as Map<String, dynamic>)[key] = value;
        });
      });

      if (patch.isNotEmpty) {
        final response = await c
            .post(
              Uri.parse('${AppConfig.bridgeBaseUrl}/config/update'),
              headers: {...bridgeHeaders(), 'Content-Type': 'application/json'},
              body: jsonEncode({
                'base_revision': base.revision,
                'patch': {
                  'engines': {
                    for (final e in patch.entries) e.key: {'params': e.value}
                  },
                },
                'updated_by': 'app-seed',
                'confirm_risk_increase': true,
              }),
            )
            .timeout(_timeout);
        if (response.statusCode != 200) {
          AppLogger.log(
              'StrategyConfig: moving engine thresholds from .env was refused (${response.statusCode}); will retry next start');
          return;
        }
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        _pending = StrategyConfigSnapshot.fromResponse(body);
        await _persist(body);
        AppLogger.log('StrategyConfig: moved ${patch.values.fold<int>(0, (n, m) => n + (m as Map).length)} engine '
            'threshold(s) from .env into the bridge (revision ${_pending!.revision})');
      }
      await prefs.setBool(_paramsSeededKey, true);
    } catch (e) {
      AppLogger.log('StrategyConfig: moving engine thresholds from .env failed ($e); will retry next start');
    }
  }

  /// First contact with a brand-new bridge config: copy what `.env` says
  /// today into it, so switching to bridge-owned config changes nothing
  /// about how the app behaves. Values are clamped to the bridge's hard
  /// bounds so an out-of-range `.env` entry can't make the whole seed fail.
  Future<void> _seedFromEnv(http.Client c, StrategyConfigSnapshot base) async {
    num clamp(String path, num value) {
      final bound = _bounds[path];
      if (bound is! Map) return value;
      final lo = bound['min'], hi = bound['max'];
      var out = value;
      if (lo is num && out < lo) out = lo;
      if (hi is num && out > hi) out = hi;
      return out;
    }

    final patch = {
      'engines': {
        EngineIds.orb: {'enabled': AppConfig.useOrbEnv},
        EngineIds.breakout: {
          'enabled': AppConfig.useBreakoutMomentumEnv,
          'dxy': AppConfig.breakoutDxyMode == 'off' || AppConfig.breakoutDxyMode == 'score'
              ? AppConfig.breakoutDxyMode
              : 'block',
        },
        EngineIds.rangeBounce: {'enabled': AppConfig.enableRangingBounceModeEnv},
      },
      'filters': {
        'dxy': {'enabled': AppConfig.useDxyFilterEnv},
      },
      'account_limits': {
        'risk_percent_per_trade': clamp('account_limits.risk_percent_per_trade', AppConfig.riskPercentPerTradeEnv),
        'max_spread_pips': clamp('account_limits.max_spread_pips', AppConfig.maxSpreadPipsEnv),
      },
      'trade_rules': {'one_active_trade': AppConfig.oneActiveTradeLimitEnv},
    };

    try {
      final response = await c
          .post(
            Uri.parse('${AppConfig.bridgeBaseUrl}/config/update'),
            headers: {...bridgeHeaders(), 'Content-Type': 'application/json'},
            body: jsonEncode({
              'base_revision': base.revision,
              'patch': patch,
              'updated_by': 'app-seed',
              'confirm_risk_increase': true,
            }),
          )
          .timeout(_timeout);
      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        _pending = StrategyConfigSnapshot.fromResponse(body);
        await _persist(body);
        AppLogger.log('StrategyConfig: seeded bridge config from .env (revision ${_pending!.revision})');
      } else {
        AppLogger.log('StrategyConfig: seeding from .env refused (${response.statusCode}): ${response.body}');
      }
    } catch (e) {
      AppLogger.log('StrategyConfig: seeding from .env failed ($e)');
    }
  }
}
