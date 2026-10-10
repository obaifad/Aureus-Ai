import '../config/app_config.dart';
import '../models/pivot.dart';
import '../models/trade_setup.dart';
import 'app_logger.dart';
import 'history_store.dart';
import 'mt5_trading_service.dart';

/// What one reconciliation pass found and fixed.
class ReconcileResult {
  /// False when the bridge could not be read (or reconciliation is off):
  /// nothing was concluded, nothing was changed.
  final bool ran;
  final String? error;

  /// Open trades the broker had closed — now recorded with the broker's own
  /// price, time, profit and reason. The caller sends their notifications.
  final List<TradeSetup> newlyClosed;

  /// Already-closed trades whose price/time/result differed from the deal
  /// history and were overwritten with the broker's numbers.
  final int corrected;

  /// Trades the app had closed on its own estimate while the REAL position
  /// was still open at the broker — reopened so real exposure stays tracked.
  final int reopened;

  /// Real positions opened by this system but missing from the app's history.
  final int adopted;
  final int stillOpen;

  /// Positions that are not ours (other magic number) — left alone.
  final int foreign;

  /// Open trades the broker neither lists as open nor as recently closed.
  final List<String> unresolved;

  const ReconcileResult({
    required this.ran,
    this.error,
    this.newlyClosed = const [],
    this.corrected = 0,
    this.reopened = 0,
    this.adopted = 0,
    this.stillOpen = 0,
    this.foreign = 0,
    this.unresolved = const [],
  });

  static const ReconcileResult skipped = ReconcileResult(ran: false);

  bool get changedAnything => newlyClosed.isNotEmpty || corrected > 0 || reopened > 0 || adopted > 0;

  /// Something a person should know about, beyond routine bookkeeping.
  bool get hasWarnings => reopened > 0 || adopted > 0 || unresolved.isNotEmpty;

  String get summary {
    final parts = <String>[
      if (newlyClosed.isNotEmpty) '${newlyClosed.length} closed by the broker',
      if (corrected > 0) '$corrected corrected from deal history',
      if (reopened > 0) '$reopened reopened (position still open on MT5)',
      if (adopted > 0) '$adopted adopted from MT5',
      if (unresolved.isNotEmpty) '${unresolved.length} not found on MT5',
    ];
    return parts.isEmpty ? 'in sync' : parts.join(', ');
  }
}

/// Keeps the app's trade log identical to what MetaTrader actually did.
///
/// For every trade backed by a real position (brokerTicket) the BROKER is the
/// source of truth: its SL/TP fills, its manual closes, its prices, its net
/// profit. The app's own price-based outcome sweep only estimates — and an
/// estimate can be wrong in either direction (spread, slippage, a stop that
/// moved) — so, once reconciliation is on, that sweep leaves ticketed trades
/// alone and this class closes, corrects or reopens them from real data.
///
/// Fails safe: if the bridge can't be read, it concludes nothing.
class BrokerReconciler {
  BrokerReconciler({Mt5TradingService? trading, DateTime Function()? clock, this.sinceHours = 96})
      : _trading = trading ?? Mt5TradingService(),
        _now = clock ?? DateTime.now;

  final Mt5TradingService _trading;
  final DateTime Function() _now;
  final int sinceHours;
  bool _running = false;

  /// A sweep-closed trade is reopened only while it is this fresh — an older
  /// mismatch is far more likely a bookkeeping gap than a live position.
  static const Duration _reopenWindow = Duration(hours: 6);

  Future<ReconcileResult> reconcile() async {
    if (!AppConfig.reconcileWithBroker || _running) return ReconcileResult.skipped;
    _running = true;
    try {
      return await _run();
    } catch (e) {
      AppLogger.log('BrokerReconciler: failed ($e)');
      return ReconcileResult(ran: false, error: '$e');
    } finally {
      _running = false;
    }
  }

  Future<ReconcileResult> _run() async {
    final snapshot = await _trading.fetchReconcile(symbol: AppConfig.brokerSymbol, sinceHours: sinceHours);
    if (snapshot == null) return const ReconcileResult(ran: false, error: 'MT5 bridge unavailable');

    final openByTicket = {for (final p in snapshot.positions) p.ticket: p};
    final closedByTicket = {for (final c in snapshot.closed) c.ticket: c};
    final now = _now().toUtc();

    final newlyClosed = <TradeSetup>[];
    final unresolved = <String>[];
    var corrected = 0, reopened = 0, adopted = 0, stillOpen = 0, foreign = 0;

    await HistoryStore.mutate((history) {
      var changed = false;
      final known = <int>{};

      for (final setup in history) {
        final ticket = setup.brokerTicket;
        if (ticket == null) continue;
        known.add(ticket);
        final position = openByTicket[ticket];
        final record = closedByTicket[ticket];

        if (setup.outcome == TradeOutcome.open) {
          if (position != null) {
            stillOpen++;
            if (_syncFill(setup, position.priceOpen)) changed = true;
          } else if (record != null && snapshot.historyOk) {
            _applyClose(setup, record);
            newlyClosed.add(setup);
            changed = true;
            AppLogger.log('🔄 Reconcile — ${setup.setupLabel} #$ticket closed on MT5 (${record.reason}) '
                '@ \$${record.priceClose.toStringAsFixed(2)}, net ${record.profit.toStringAsFixed(2)}');
          } else {
            unresolved.add('${setup.setupLabel} #$ticket');
          }
          continue;
        }

        // Closed in the app. The broker disagrees if the position is still open…
        final closedRecently = setup.closedAt != null && now.difference(setup.closedAt!.toUtc()) < _reopenWindow;
        final closedByEstimate = setup.outcome == TradeOutcome.win || setup.outcome == TradeOutcome.loss;
        if (position != null && closedRecently && closedByEstimate) {
          setup
            ..outcome = TradeOutcome.open
            ..closedPrice = null
            ..closedAt = null
            ..brokerProfit = null
            ..closeReason = null;
          reopened++;
          changed = true;
          AppLogger.log('⚠️ Reconcile — ${setup.setupLabel} #$ticket was marked closed but the MT5 position is '
              'still OPEN; reopened so it stays tracked');
        } else if (record != null && snapshot.historyOk && _applyClose(setup, record)) {
          // …or if it closed at a different price/time than the app recorded.
          corrected++;
          changed = true;
        }
      }

      // Real positions of ours that the app has no record of.
      for (final position in snapshot.positions) {
        if (known.contains(position.ticket)) continue;
        if (!AppConfig.aureusMagicNumbers.contains(position.magic)) {
          foreign++;
          continue;
        }
        history.insert(0, _adopt(position, now));
        adopted++;
        changed = true;
        AppLogger.log('⚠️ Reconcile — adopted MT5 position #${position.ticket} '
            '(${position.direction == TradeDirection.buy ? "BUY" : "SELL"} @ \$${position.priceOpen.toStringAsFixed(2)}) '
            'that the app had no record of');
      }
      return changed;
    });

    return ReconcileResult(
      ran: true,
      newlyClosed: newlyClosed,
      corrected: corrected,
      reopened: reopened,
      adopted: adopted,
      stillOpen: stillOpen,
      foreign: foreign,
      unresolved: unresolved,
    );
  }

  static double _round2(double v) => double.parse(v.toStringAsFixed(2));

  /// The broker's fill price is the real entry; the signal price is only the
  /// candle close it was derived from.
  bool _syncFill(TradeSetup setup, double brokerOpen) {
    final fill = _round2(brokerOpen);
    if (setup.actualFillPrice != null && (setup.actualFillPrice! - fill).abs() <= 0.004) return false;
    setup.actualFillPrice = fill;
    return true;
  }

  TradeOutcome _outcomeFor(String reason, TradeOutcome current) => switch (reason) {
        'tp' => TradeOutcome.win,
        'sl' || 'stop_out' => TradeOutcome.loss,
        _ => current == TradeOutcome.open ? TradeOutcome.manualClose : current,
      };

  /// Writes the broker's deal data onto [setup]. Returns whether anything
  /// actually changed (so a repeat pass over an already-correct trade is a
  /// no-op).
  bool _applyClose(TradeSetup setup, BrokerClosedPosition record) {
    var changed = _syncFill(setup, record.priceOpen);

    final price = _round2(record.priceClose);
    if (setup.closedPrice == null || (setup.closedPrice! - price).abs() > 0.004) {
      setup.closedPrice = price;
      changed = true;
    }
    final at = DateTime.fromMillisecondsSinceEpoch(record.timeClose * 1000, isUtc: true);
    if (setup.closedAt == null || setup.closedAt!.toUtc().difference(at).abs() > const Duration(seconds: 2)) {
      setup.closedAt = at;
      changed = true;
    }
    final outcome = _outcomeFor(record.reason, setup.outcome);
    if (setup.outcome != outcome) {
      setup.outcome = outcome;
      changed = true;
    }
    if (setup.brokerProfit == null || (setup.brokerProfit! - record.profit).abs() > 0.004) {
      setup.brokerProfit = record.profit;
      changed = true;
    }
    if (setup.closeReason != record.reason) {
      setup.closeReason = record.reason;
      changed = true;
    }
    return changed;
  }

  TradeSetup _adopt(BrokerPosition position, DateTime now) => TradeSetup(
        symbol: AppConfig.symbol,
        direction: position.direction,
        timeframeLabel: 'MT5',
        setupType: SetupType.confluence,
        entry: _round2(position.priceOpen),
        stopLoss: _round2(position.stopLoss),
        takeProfit: _round2(position.takeProfit),
        pattern: CandlePattern.none,
        detectedAt: position.timeOpen ?? now,
        aiReason: 'Adopted from MT5: position #${position.ticket} was opened by this system but was '
            'missing from the app\'s history.',
        dataSource: 'MT5 (adopted)',
        lotSize: position.volume,
        brokerTicket: position.ticket,
        actualFillPrice: _round2(position.priceOpen),
      );
}
