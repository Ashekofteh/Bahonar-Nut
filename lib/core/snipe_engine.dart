/// The snipe engine: the loop that actually wins a listing.
///
/// Assembly rather than invention — every part it needs already exists and is
/// tested. This file wires them together and owns the one thing none of them
/// can own alone: the ordering of decisions within a live hunt.
///
/// The ordering is the whole design, and it is deliberate:
///   1. Preflight, before the loop. Never discover a dead session mid-hunt.
///   2. Poll, then filter tombstoned listings, then rank. A dead listing must
///      never reach the ranker, because a match on a dead listing costs a claim
///      attempt that looks like a retry attack.
///   3. One in-flight claim, ever. Serialised per account.
///   4. On ambiguity, reconcile — never retry. This is the double-purchase guard.
///
/// Fully testable with fakes: the client, clock and sleep are all injected, so
/// the whole hunt runs deterministically in milliseconds.
library;

import 'dart:async';
import 'dart:math';

import 'ledger.dart';
import 'models.dart';
import 'polling.dart';
import 'portal.dart';
import 'preflight.dart';
import 'priority.dart';
import 'session_manager.dart';
import 'snipe.dart';
import 'time.dart';
import 'tombstone.dart';

/// Signals the engine to end before its natural termination.
class SnipeCancelled implements Exception {
  const SnipeCancelled();

  @override
  String toString() => 'SnipeCancelled';
}

/// The engine's public surface, matching the frozen spec interface.
abstract class SnipeEngine {
  /// Starts a rule. Idempotent for an already-running rule.
  Future<void> start(SnipeRule rule);

  /// Stops a running rule and releases its resources.
  Future<void> stop(String ruleId);

  /// Live state for the UI.
  Stream<SnipeRunStatus> watch(String ruleId);
}

/// Concrete engine.
class DefaultSnipeEngine implements SnipeEngine {
  DefaultSnipeEngine({
    required this._client,
    required this._sessions,
    required this._clock,
    this._ranker = const PriorityRanker(),
    this._preflight = const PreflightChecker(),
    this._reconciler = const ClaimReconciler(),
    this._defaultPolicy = const PollingPolicy(),
    Random? random,
    Future<void> Function(Duration)? sleep,
  })  : _random = random ?? Random(),
        _sleep = sleep ?? Future<void>.delayed;

  final PortalClient _client;
  final SessionManager _sessions;
  final ServerClock _clock;
  final PriorityRanker _ranker;
  final PreflightChecker _preflight;
  final ClaimReconciler _reconciler;
  final PollingPolicy _defaultPolicy;
  final Random _random;

  /// Injected so tests advance the loop without waiting real time.
  ///
  /// A test that had to sleep 45 jittered seconds per iteration would be slow
  /// enough that nobody would run it, and an untested hunt loop is exactly the
  /// code that must not be taken on faith.
  final Future<void> Function(Duration) _sleep;

  final Map<String, _Run> _runs = {};

  /// Ledgers outlive their runs: a completed run is removed from [_runs], but
  /// its ledger stays readable so a purchase can be explained after the fact.
  /// Each ledger is already bounded (see [SnipeLedger.maxEntries]).
  final Map<String, SnipeLedger> _ledgers = {};

  @override
  Future<void> start(SnipeRule rule) async {
    if (_runs.containsKey(rule.id)) return; // idempotent

    final run = _Run(rule: rule, status: _initialStatus(rule));
    _runs[rule.id] = run;
    _ledgers[rule.id] = run.ledger;

    // Kick off the loop without blocking the caller: `start` returns once the
    // run is registered, so the UI can subscribe before the first poll.
    run.future = _runLoop(run);
  }

  @override
  Future<void> stop(String ruleId) async {
    final run = _runs[ruleId];
    if (run == null) return;
    run.cancel();
    try {
      await run.future;
    } catch (_) {
      // Cancellation is expected to surface as an error from the loop.
    }
    _runs.remove(ruleId);
  }

  @override
  Stream<SnipeRunStatus> watch(String ruleId) {
    final run = _runs[ruleId];
    if (run == null) return const Stream.empty();
    return run.controller.stream;
  }

  /// The ledger for a run, for the log screen and for tests.
  ///
  /// Survives the run's completion: explaining a purchase after the fact is the
  /// ledger's entire purpose.
  SnipeLedger? ledgerFor(String ruleId) => _ledgers[ruleId];

  /// Whether a rule is currently running.
  bool isRunning(String ruleId) => _runs.containsKey(ruleId);

  SnipeRunStatus _initialStatus(SnipeRule rule) => SnipeRunStatus(
        ruleId: rule.id,
        state: SnipeState.idle,
      );

  Future<void> _runLoop(_Run run) async {
    final rule = run.rule;
    final ledger = run.ledger;

    try {
      _transition(run, SnipeState.preflight);
      ledger.record(
        at: _clock.isSynced ? _clock.nowUtc : DateTime.now().toUtc(),
        kind: LedgerEventKind.started,
        message: 'اجرای قانون آغاز شد.',
      );

      // --- Preflight ---
      final sessionResult = await _sessions.ensureSession(rule.account);
      final session = _sessions.sessionFor(rule.account);

      Balance? balance;
      if (session != null) {
        try {
          balance = await _client.fetchBalance(session);
        } catch (_) {
          balance = null; // Preflight reports this as balanceUnreadable.
        }
      }

      final verdict = _preflight.check(
        rule: rule,
        clock: _clock,
        session: sessionResult,
        balance: balance,
        cheapestConsidered: _cheapestConsidered(rule),
      );

      if (!verdict.passed) {
        ledger.record(
          at: DateTime.now().toUtc(),
          kind: LedgerEventKind.preflightFailed,
          message: verdict.detail ?? 'پیش‌نیازها برقرار نبود.',
        );
        _finish(run, SnipeState.aborted, verdict.detail ?? 'preflight failed');
        return;
      }

      ledger.record(
        at: _now(),
        kind: LedgerEventKind.preflightPassed,
        message: 'پیش‌نیازها بررسی شد.',
      );

      _transition(run, SnipeState.hunting);

      // --- Hunt ---
      await _hunt(run, session!, balance);
    } on SnipeCancelled {
      _finish(run, SnipeState.windowExpired, 'stopped by user');
    } catch (error) {
      ledger.record(
        at: DateTime.now().toUtc(),
        kind: LedgerEventKind.runEnded,
        message: 'اجرا با خطا پایان یافت: $error',
      );
      _finish(run, SnipeState.aborted, error.toString());
    } finally {
      // A finished run leaves the registry: otherwise `isRunning` would lie
      // forever and the run would leak. The ledger survives in `_ledgers`.
      _runs.remove(rule.id);
      run.controller.close();
    }
  }

  Future<void> _hunt(_Run run, Session session, Balance? balance) async {
    final rule = run.rule;
    final policy = _defaultPolicy;
    final breaker = CircuitBreaker(policy.failureThreshold);
    final budget = RequestBudget(policy.requestBudget);

    while (!run.isCancelled) {
      // Window check each cycle: the window can close mid-hunt.
      if (_clock.isSynced) {
        final portalNow = _clock.portalNow;
        if (!rule.isWithinWindow(ClockTime(portalNow.hour, portalNow.minute))) {
          run.ledger.record(
            at: _now(),
            kind: LedgerEventKind.runEnded,
            message: 'بازه زمانی به پایان رسید.',
          );
          _finish(run, SnipeState.windowExpired, 'window closed');
          return;
        }
      }

      if (budget.isExhausted) {
        run.ledger.record(
          at: _now(),
          kind: LedgerEventKind.runEnded,
          message: 'سهمیه درخواست این اجرا به پایان رسید.',
        );
        _finish(run, SnipeState.windowExpired, 'budget exhausted');
        return;
      }

      budget.spend();
      final pollOk = await _pollOnce(run, session, balance);

      if (pollOk) {
        breaker.recordSuccess();
      } else {
        if (breaker.recordFailure()) {
          run.ledger.record(
            at: _now(),
            kind: LedgerEventKind.runEnded,
            message: 'پس از چند خطای متوالی، اجرا متوقف شد.',
          );
          _finish(run, SnipeState.aborted, 'circuit open');
          return;
        }
      }

      // A completed claim ends the run.
      if (SnipeStateMachine.isTerminal(run.status.state)) return;

      final interval = policy.nextInterval(
        consecutiveFailures: breaker.consecutiveFailures,
        random: _random,
      );
      await _sleep(interval);
    }
    throw const SnipeCancelled();
  }

  /// One poll cycle. Returns false when the poll itself failed.
  ///
  /// Returns true when the poll succeeded, whether or not a match was found —
  /// "found nothing" is a healthy outcome, not a failure, and treating it as one
  /// would trip the circuit breaker on a quiet market.
  Future<bool> _pollOnce(_Run run, Session session, Balance? balance) async {
    final rule = run.rule;
    final now = _now();

    final BasketPage page;
    try {
      page = await _client.fetchBasket(session);
    } catch (error) {
      run.bumpPoll(now, error: error.toString());
      run.ledger.record(
        at: now,
        kind: LedgerEventKind.polled,
        message: 'خطا در دریافت سبد: $error',
      );
      return false;
    }

    run.bumpPoll(now);

    // Filter tombstones before ranking: a dead listing must never reach the
    // ranker, or a match on it costs a claim attempt that reads as a retry.
    final live = run.tombstones.filter(rule.account, page.listings, now);
    final skipped = page.listings.length - live.length;

    run.ledger.record(
      at: now,
      kind: LedgerEventKind.polled,
      message: '${page.listings.length} آگهی بررسی شد'
          '${skipped > 0 ? "، $skipped مورد حذف‌شده" : ""}.',
    );

    // Restrict to the slots this rule covers.
    final candidates = live.where((l) => rule.slots.contains(l.slot));

    final best = _rankAcrossSlots(rule, candidates, run);
    if (best == null) return true;

    _transition(run, SnipeState.matched);
    run.ledger.record(
      at: now,
      kind: LedgerEventKind.matched,
      message: 'آگهی مناسب پیدا شد: ${best.option.name}',
      listingId: best.id,
      simulated: rule.dryRun,
    );

    await _claim(run, session, best);
    return true;
  }

  /// Ranks candidates, and records why each was skipped.
  Listing? _rankAcrossSlots(
    SnipeRule rule,
    Iterable<Listing> candidates,
    _Run run,
  ) {
    // Group by slot: a SlotPreference is per meal, so ranking across slots in one
    // pass would compare options that are not alternatives.
    final bySlot = <MealSlot, List<Listing>>{};
    for (final listing in candidates) {
      bySlot.putIfAbsent(listing.slot, () => []).add(listing);
    }

    Listing? best;
    for (final entry in bySlot.entries) {
      final preference = rule.preferences[entry.key];
      if (preference == null) continue;

      final result = _ranker.selectBest(
        preference: preference,
        listings: entry.value,
        maxPriceRial: rule.maxPriceRial,
      );

      for (final candidate in result.considered) {
        if (candidate.isEligible) continue;
        run.ledger.record(
          at: _now(),
          kind: LedgerEventKind.skipped,
          message: 'رد شد (${candidate.rejection?.name}): '
              '${candidate.listing.option.name}',
          listingId: candidate.listing.id,
          simulated: rule.dryRun,
        );
      }

      final winner = result.best;
      if (winner == null) continue;
      if (best == null || winner.priceRial < best.priceRial) best = winner;
    }
    return best;
  }

  Future<void> _claim(_Run run, Session session, Listing listing) async {
    final rule = run.rule;
    final now = _now();

    // --- Dry run: record and stop, without ever calling the write path. ---
    if (rule.dryRun) {
      run.ledger.record(
        at: now,
        kind: LedgerEventKind.claimSucceeded,
        message: 'شبیه‌سازی: این آگهی خریداری می‌شد.',
        listingId: listing.id,
        simulated: true,
      );
      run.countPurchase(now);
      _finish(run, SnipeState.claimed, 'dry run match');
      return;
    }

    _transition(run, SnipeState.claiming);
    run.ledger.record(
      at: now,
      kind: LedgerEventKind.claimAttempted,
      message: 'تلاش برای خرید ${listing.option.name}',
      listingId: listing.id,
    );

    final ClaimResult result;
    try {
      result = await _client.claim(session, listing.id);
    } catch (error) {
      // A thrown claim is ambiguous by definition: we do not know whether the
      // server processed it before the connection failed.
      await _handleAmbiguous(run, session, listing, error.toString());
      return;
    }

    switch (result) {
      case ClaimSucceeded(:final reservation):
        run.ledger.record(
          at: _now(),
          kind: LedgerEventKind.claimSucceeded,
          message: 'خرید انجام شد: ${reservation.option.name}',
          listingId: listing.id,
        );
        run.setClaimed(listing.id);
        run.countPurchase(_now());
        _finish(run, SnipeState.claimed, 'claimed');

      case ClaimRejected(:final reason):
        run.tombstones.add(
          accountId: rule.account,
          listingId: listing.id,
          reason: TombstoneReason.claimRejected,
          now: _now(),
          listingExpiresAt: listing.expiresAt,
        );
        run.ledger.record(
          at: _now(),
          kind: LedgerEventKind.claimLost,
          message: 'خرید انجام نشد: $reason',
          listingId: listing.id,
        );
        _transition(run, SnipeState.lost);
        _transition(run, SnipeState.hunting);

      case ClaimAmbiguous(:final diagnostic):
        await _handleAmbiguous(run, session, listing, diagnostic);
    }
  }

  /// Resolves an ambiguous claim by re-reading, then never retries it.
  Future<void> _handleAmbiguous(
    _Run run,
    Session session,
    Listing listing,
    String diagnostic,
  ) async {
    final rule = run.rule;

    run.ledger.record(
      at: _now(),
      kind: LedgerEventKind.claimAmbiguous,
      message: 'نتیجه خرید نامشخص بود، بررسی مجدد انجام می‌شود.',
      listingId: listing.id,
    );

    final outcome = await _reconciler.reconcile(
      client: _client,
      session: session,
      listing: listing,
    );

    // Whatever the outcome, this listing is never claimed again. If it did land,
    // retrying buys a second meal; if it did not, retrying is the dead-listing
    // poll pattern. Nothing good comes from a second attempt.
    run.tombstones.add(
      accountId: rule.account,
      listingId: listing.id,
      reason: TombstoneReason.lostRace,
      now: _now(),
      listingExpiresAt: listing.expiresAt,
    );

    switch (outcome) {
      case ReconciliationOutcome.claimed:
        // The purchase did happen — the claim landed and only our knowledge was
        // late. Record it as a purchase, not just a reconciliation note, or the
        // ledger understates what the user was charged.
        run.ledger.record(
          at: _now(),
          kind: LedgerEventKind.claimSucceeded,
          message: 'بررسی مجدد نشان داد خرید انجام شده است.',
          listingId: listing.id,
        );
        run.ledger.record(
          at: _now(),
          kind: LedgerEventKind.reconciled,
          message: 'نتیجه نامشخص بود و با بررسی مجدد تأیید شد.',
          listingId: listing.id,
        );
        run.setClaimed(listing.id);
        run.countPurchase(_now());
        _finish(run, SnipeState.claimed, 'reconciled as claimed');

      case ReconciliationOutcome.notClaimed:
        run.ledger.record(
          at: _now(),
          kind: LedgerEventKind.reconciled,
          message: 'بررسی مجدد نشان داد خرید انجام نشده است.',
          listingId: listing.id,
        );
        _transition(run, SnipeState.lost);
        _transition(run, SnipeState.hunting);

      case ReconciliationOutcome.indeterminate:
        // Still unknown. Treat as lost and move on: continuing to hunt risks
        // more than it gains, and the tombstone prevents the dangerous retry.
        run.ledger.record(
          at: _now(),
          kind: LedgerEventKind.reconciled,
          message: 'بررسی مجدد قطعی نبود؛ این آگهی دیگر تلاش نمی‌شود.',
          listingId: listing.id,
        );
        _transition(run, SnipeState.lost);
        _transition(run, SnipeState.hunting);
    }
  }

  int? _cheapestConsidered(SnipeRule rule) {
    // Only meaningful when a ceiling exists; otherwise funds cannot be judged
    // from the rule alone and preflight skips the check.
    if (rule.maxPriceRial == null) return null;
    return rule.maxPriceRial;
  }

  DateTime _now() => _clock.isSynced ? _clock.nowUtc : DateTime.now().toUtc();

  void _transition(_Run run, SnipeState next) {
    // A cancelled run keeps whatever state it reached; transitions after
    // cancellation are meaningless rather than errors.
    if (run.isCancelled && !SnipeStateMachine.isTerminal(next)) return;
    run.status = run.status.withState(next);
    run.emit();
  }

  void _finish(_Run run, SnipeState state, String reason) {
    run.status = run.status.withState(state, stopReason: reason);
    run.emit();
  }
}

/// Mutable state for one running rule.
class _Run {
  _Run({required this.rule, required this.status})
      : ledger = SnipeLedger(rule.id);

  final SnipeRule rule;
  final SnipeLedger ledger;
  final TombstoneSet tombstones = TombstoneSet();
  final StreamController<SnipeRunStatus> controller =
      StreamController<SnipeRunStatus>.broadcast();

  SnipeRunStatus status;
  Future<void> future = Future<void>.value();
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;

  void emit() {
    if (!controller.isClosed) controller.add(status);
  }

  void bumpPoll(DateTime at, {String? error}) {
    status = status.withPoll(at, error: error);
    emit();
  }

  void setClaimed(ListingId listingId) {
    status = status.withClaimed(listingId);
    emit();
  }

  void countPurchase(DateTime at) {
    status = status.withPurchase(at);
    emit();
  }
}
