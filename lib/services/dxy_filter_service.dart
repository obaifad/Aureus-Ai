import '../config/app_config.dart';
import '../models/candle.dart';
import '../models/pivot.dart';
import 'app_logger.dart';
import 'data_service.dart';

/// Lightweight XAUUSD/DXY correlation confirmation filter (2026-09-18,
/// explicit request). Gold and the US Dollar Index trade near-permanently
/// inverse, so a XAUUSD BUY firing while DXY is itself in a clear bullish
/// trend is fighting its own strongest cross-asset headwind, and
/// symmetrically for a SELL against a weak DXY.
///
/// Deliberately NEVER an independent trigger — [confirms] only ever
/// answers "does DXY agree with a trade this system already decided to
/// take". Every failure mode — filter disabled, mock data, no resolvable
/// symbol, feed unreachable, not enough candles, an unclear DXY trend —
/// resolves to `true` (bypass), never to a block: a missing confirmation
/// is not the same thing as a contradiction, and the explicit request is
/// "gracefully bypass... without stopping or crashing" on any of these.
class DxyFilterService {
  final DataService _dataService;
  final Mt5BridgeDataService _bridge = Mt5BridgeDataService();

  String? _resolvedSymbol;
  List<Candle>? _cachedCandles;
  DateTime? _cachedAt;

  DxyFilterService([DataService? dataService]) : _dataService = dataService ?? DataService();

  /// True when [direction] should be ALLOWED to fire. Never throws — every
  /// internal failure is caught and logged once, then treated as bypass.
  Future<bool> confirms(TradeDirection direction) async {
    if (!AppConfig.useDxyFilter) return true;
    // Mock mode has no real DXY signal to read at all — bypassing here
    // (rather than feeding MockDataService a symbol it silently ignores,
    // see its own doc comment) keeps that fact explicit at the call site
    // instead of hiding it inside a data source that quietly does nothing.
    if (AppConfig.useMockData) return true;

    try {
      final candles = await _dxyCandles();
      if (candles == null) return true; // couldn't resolve a symbol, or fetch failed
      final trend = _trend(candles);
      if (trend == null) return true; // DXY itself is flat/unclear — don't block on it

      // BUY XAUUSD wants DXY WEAK (bearish); SELL wants DXY STRONG (bullish).
      final dxyBullish = trend == TradeDirection.buy;
      return direction == TradeDirection.buy ? !dxyBullish : dxyBullish;
    } catch (e) {
      AppLogger.log('DXY filter bypassed — $e');
      return true;
    }
  }

  Future<List<Candle>?> _dxyCandles() async {
    final now = DateTime.now();
    if (_cachedCandles != null && _cachedAt != null && now.difference(_cachedAt!) < AppConfig.dxyCacheTtl) {
      return _cachedCandles;
    }

    final symbol = await _resolveSymbol();
    if (symbol == null) return null;

    try {
      final candles = await _dataService.getCandles(
        timeframeMinutes: AppConfig.dxyTrendTimeframeMinutes,
        count: AppConfig.dxyTrendLookbackCandles + 5,
        symbol: symbol,
      );
      _cachedCandles = candles;
      _cachedAt = now;
      return candles;
    } catch (e) {
      AppLogger.log('DXY candle fetch failed for "$symbol" — $e');
      return null;
    }
  }

  /// Manual override first; otherwise auto-detects a Market Watch symbol
  /// via the MT5 bridge (tried under a few common aliases, since brokers
  /// name the Dollar Index as inconsistently as they name gold — see
  /// AppConfig.brokerSymbol's own comment); falls back to Yahoo Finance's
  /// public "DX-Y.NYB" ticker (needs no broker/API key at all) when the
  /// bridge is disabled, unreachable, or has no match. Resolved once and
  /// cached for the life of this service instance — SignalChecker creates
  /// one DxyFilterService for its own lifetime, same as every other engine.
  Future<String?> _resolveSymbol() async {
    if (_resolvedSymbol != null) return _resolvedSymbol;

    final manual = AppConfig.dxySymbolName.trim();
    if (manual.isNotEmpty) return _resolvedSymbol = manual;

    if (!AppConfig.disableMt5Bridge) {
      for (final alias in const ['DXY', 'USDX', 'DOLLAR']) {
        final found = await _bridge.findSymbol(alias);
        if (found != null) return _resolvedSymbol = found;
      }
    }

    return _resolvedSymbol = 'DX-Y.NYB';
  }

  /// Same net-movement-over-N-candles reading SignalChecker's own
  /// [_hourlyBias]/[_fourHourBias] use for XAUUSD's macro bias — "DXY's
  /// trend" means the same kind of thing everywhere in this codebase. Null
  /// when the move is too small to call, or there isn't enough history.
  TradeDirection? _trend(List<Candle> candles) {
    const lookback = AppConfig.dxyTrendLookbackCandles;
    if (candles.length < lookback ~/ 2) return null;
    final window = candles.length > lookback ? candles.sublist(candles.length - lookback) : candles;
    if (window.length < 2) return null;
    final diff = window.last.close - window.first.close;
    // DXY trades in single-digit-point ranges (unlike gold's $2,000+
    // scale), so this needs its own noise floor rather than reusing
    // AppConfig.slBufferDollars the way the XAUUSD bias readings do.
    const double noiseFloor = 0.05;
    if (diff.abs() < noiseFloor) return null;
    return diff > 0 ? TradeDirection.buy : TradeDirection.sell;
  }
}
