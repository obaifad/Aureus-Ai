import '../models/pivot.dart';
import '../models/trade_setup.dart';
import 'app_logger.dart';
import 'history_store.dart';
import 'mt5_trading_service.dart';
import 'pending_store.dart';

/// What the bridge said when a trade was proposed for approval.
class ProposalOutcome {
  /// pending | blocked | failed | error | unreachable
  final String state;
  final String? reason;
  const ProposalOutcome(this.state, [this.reason]);

  bool get isPending => state == 'pending';
}

/// A proposal that ended without a trade (rejected, expired, blocked, failed,
/// or lost track of) — its engine should be released. Unless it was lost, it
/// is also kept in the history as a not-traded signal (see [TradeSetup.isMissed]).
class ReleasedApproval {
  final PendingApproval approval;

  /// rejected | expired | blocked | failed | lost
  final String state;
  const ReleasedApproval(this.approval, this.state);
}

class ApprovalSyncResult {
  /// Proposals the owner approved and the bridge executed — now in the
  /// trade history as real, ticketed positions.
  final List<TradeSetup> executed;
  final List<ReleasedApproval> released;
  final int stillPending;
  const ApprovalSyncResult({this.executed = const [], this.released = const [], this.stillPending = 0});

  bool get changedAnything => executed.isNotEmpty || released.isNotEmpty;
}

/// The app's half of "approve this trade on Telegram": it PROPOSES, the
/// bridge asks the owner, re-checks the market at the moment of approval and
/// trades. This class sends the proposal, remembers it, and later learns the
/// outcome from the bridge.
class ApprovalService {
  ApprovalService({Mt5TradingService? trading, DateTime Function()? clock})
      : _trading = trading ?? Mt5TradingService(),
        _now = clock ?? DateTime.now;

  final Mt5TradingService _trading;
  final DateTime Function() _now;

  /// How long past its deadline an unreachable bridge may keep a proposal alive
  /// in the app before it is given up on.
  static const Duration _unreachableGrace = Duration(minutes: 5);
  static const Duration _notFoundGrace = Duration(seconds: 10);

  Future<ProposalOutcome> submit(TradeSetup setup, String engineId) async {
    final submission = await _trading.submitPending(setup);
    if (!submission.isPending) {
      return ProposalOutcome(submission.state == 'pending' ? 'failed' : submission.state, submission.reason);
    }
    final now = _now().toUtc();
    await PendingStore.add(PendingApproval(
      setup: setup,
      engineId: engineId,
      submittedAt: now,
      expiresAt: submission.expiresAt ?? now.add(const Duration(seconds: 90)),
    ));
    AppLogger.log('📲 Proposed ${setup.setupLabel} @ \$${setup.entry.toStringAsFixed(2)} for Telegram approval');
    return const ProposalOutcome('pending');
  }

  /// Asks the bridge what became of every waiting proposal.
  Future<ApprovalSyncResult> sync() async {
    final waiting = await PendingStore.load();
    if (waiting.isEmpty) return const ApprovalSyncResult();
    final now = _now().toUtc();
    final executed = <TradeSetup>[];
    final released = <ReleasedApproval>[];
    var stillPending = 0;

    for (final approval in waiting) {
      final status = await _trading.getSignal(approval.uid);

      if (status == null) {
        // Bridge unreachable: it may still be waiting. Only give up long after the deadline.
        if (now.isAfter(approval.expiresAt.add(_unreachableGrace))) {
          await PendingStore.remove(approval.uid);
          released.add(ReleasedApproval(approval, 'lost'));
        } else {
          stillPending++;
        }
        continue;
      }
      if (status.notFound) {
        if (now.isAfter(approval.expiresAt.add(_notFoundGrace))) {
          await PendingStore.remove(approval.uid);
          released.add(ReleasedApproval(approval, 'lost'));
        } else {
          stillPending++;
        }
        continue;
      }

      switch (status.state) {
        case 'pending' || 'executing':
          stillPending++;
        case 'executed':
          final setup = _imported(approval.setup, status);
          if (setup != null) {
            await _addToHistory(setup);
            executed.add(setup);
          }
          await PendingStore.remove(approval.uid);
        default: // rejected | expired | blocked | failed
          await PendingStore.remove(approval.uid);
          await _recordMissed(approval, status.state);
          released.add(ReleasedApproval(approval, status.state));
      }
    }
    return ApprovalSyncResult(executed: executed, released: released, stillPending: stillPending);
  }

  /// The proposal, now a real position: the broker's ticket, fill price and
  /// the lot the bridge sized at approval time.
  TradeSetup? _imported(TradeSetup proposed, SignalStatus status) {
    final ticket = status.ticket;
    if (ticket == null) {
      AppLogger.log('ApprovalService: bridge reported ${proposed.uid} executed without a ticket — ignored');
      return null;
    }
    final setup = TradeSetup.fromJson(proposed.toJson())
      ..brokerTicket = ticket
      ..actualFillPrice = status.price ?? proposed.entry
      ..lotSize = status.volume ?? proposed.lotSize
      ..dataSource = 'MT5 (approved)'
      ..aiReason = '• You approved this trade on Telegram.\n'
          '• ${proposed.pattern.shapeLabel} confirmation on a ${proposed.setupType.label} setup; '
          'filled at \$${(status.price ?? proposed.entry).toStringAsFixed(2)}.';
    return setup;
  }

  /// A proposal that ended without a trade stays in the history as a signal nobody traded: it is tracked to
  /// its stop or target, so you can see what you missed (or avoided), but it is flagged
  /// ([TradeSetup.notTradedReason]) and therefore kept out of the stats, the one-active-trade guard and the
  /// close button. Without this an expired proposal vanished from the app and from Telegram's own message.
  Future<void> _recordMissed(PendingApproval approval, String state) async {
    final setup = TradeSetup.fromJson(approval.setup.toJson())
      ..notTradedReason = state
      ..lotSize = null;
    final why = setup.notTradedLabel ?? state;
    setup.aiReason = '• Not traded: $why.\n'
        '• ${setup.pattern.shapeLabel} confirmation on a ${setup.setupType.label} setup — '
        'tracked to its stop or target to show what it would have done.';
    var added = false;
    await HistoryStore.mutate((history) {
      if (history.any((h) => h.uid == setup.uid)) return false; // recorded already
      history.insert(0, setup);
      added = true;
      return true;
    });
    if (added) {
      AppLogger.log('📭 ${setup.setupLabel} @ \$${setup.entry.toStringAsFixed(2)} was not traded '
          '($why) — tracking what it would have done');
    }
  }

  Future<void> _addToHistory(TradeSetup setup) async {
    await HistoryStore.mutate((history) {
      // Reconciliation may have adopted this very position a moment before we
      // learned of it; the full setup replaces that bare placeholder.
      history.removeWhere((h) => h.brokerTicket == setup.brokerTicket && h.dataSource == 'MT5 (adopted)');
      if (history.any((h) => h.brokerTicket == setup.brokerTicket)) return true; // already imported
      history.insert(0, setup);
      return true;
    });
  }
}
