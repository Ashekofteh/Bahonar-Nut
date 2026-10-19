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

import 'hunt_config.dart';
import 'hunt_ranker.dart';
import 'ledger.dart';
import 'models.dart';
import 'persian.dart';
import 'polling.dart';
import 'portal.dart';
import 'preflight.dart';
import 'priority.dart';
import 'session.dart';
import 'session_manager.dart';
import 'snipe.dart';
import 'time.dart';
import 'tombstone.dart';

/// Notified when a hunt ends, so the platform layer can release the service
/// and the UI can say what happened.
///
/// An interface rather than a callback so the engine keeps no reference to the
/// platform: the whole loop stays testable on the VM.
abstract class HuntOutcomeListener {
  /// A meal was bought.
  Future<void> onClaimed({
    required String ruleId,
    required Listing listing,
    required Reservation reservation,
  });

  /// The run ended without buying: window closed, budget spent, cancelled, or
  /// a precondition failed.
  Future<void> onEnded({
    required String ruleId,
    required SnipeState state,
    required String reason,
  });
}

/// An optional no-op listener, for tests and for callers that do not care.
class NoopHuntListener implements HuntOutcomeListener {
  const NoopHuntListener();

  @override
  Future<void> onClaimed({
    required String ruleId,
    required Listing listing,
    required Reservation reservation,
  }) async {}

  @override
  Future<void> onEnded({
    required String ruleId,
    required SnipeState state,
    required String reason,
  }) async {}
}

/// Signals the engine to end before its natural termination.
class SnipeCancelled implements Exception {
  const SnipeCancelled();

  @override
  String toString() => 'SnipeCancelled';
}

/// The engine's public surface, matching the frozen spec interface.
abstract class SnipeEngine {
  /// Starts a rule. Idempotent for an already-running rule.
  ///
  /// [hunt] is the hunt configuration, when the rule is a hunt. It supplies
  /// the window, the peak/off-peak rate and the priority list the rule's own
  /// fields cannot express.
  Future<void> start(SnipeRule rule, {HuntConfig? hunt});

  /// Runs the pre-flight checks without starting the hunt.
  ///
  /// The screen calls this so the user sees a verdict — and a refusal — before
  /// anything is bought.
  Future<PreflightResult> preflight(SnipeRule rule, {HuntConfig? hunt});

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
    this._huntRanker = const HuntRanker(),
    this._preflight = const PreflightChecker(),
    this._reconciler = const ClaimReconciler(),
    this._defaultPolicy = const PollingPolicy(),
    this._listener = const NoopHuntListener(),
    Random? random,
    Future<void> Function(Duration)? sleep,
  })  : _random = random ?? Random(),
        _sleep = sleep ?? Future<void>.delayed;

  final PortalClient _client;
  final SessionManager _sessions;
  final ServerClock _clock;
  final PriorityRanker _ranker;
  final HuntRanker _huntRanker;
  final PreflightChecker _preflight;
  final ClaimReconciler _reconciler;
  final PollingPolicy _defaultPolicy;
  final HuntOutcomeListener _listener;
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

  /// The hunt configuration per rule, when the caller supplied one.
  final Map<String, HuntConfig> _huntConfigs = {};

  @override
  Future<void> start(SnipeRule rule, {HuntConfig? hunt}) async {
    if (_runs.containsKey(rule.id)) return; // idempotent

    if (hunt != null) _huntConfigs[rule.id] = hunt;

    final run = _Run(rule: rule, status: _initialStatus(rule), hunt: hunt);
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

  /// Runs the pre-flight checks without starting the hunt.
  ///
  /// The hunt screen calls this to show the user a verdict **before** anything
  /// is bought: the dish, the hall, the window, the projected request count —
  /// or the reason the hunt would be refused. Only then does the user press
  /// start.
  ///
  /// A pre-flight failure is free: it costs the reads the check itself needs
  /// and nothing more. A failure discovered mid-hunt has already spent the
  /// request budget and possibly the money.
  @override
  Future<PreflightResult> preflight(SnipeRule rule, {HuntConfig? hunt}) async {
    final inputs = await _readPreflightInputs(rule);
    return _preflight.check(
      rule: rule,
      clock: _clock,
      session: inputs.session,
      balance: inputs.balance,
      requiredCredit: hunt?.requiredCreditRial,
      targetDate: hunt?.targetDate,
      holdings: inputs.holdings,
      hunt: hunt,
    );
  }

  /// The reads a pre-flight needs: the session, the balance and the holdings.
  ///
  /// A read that fails yields null rather than throwing, because "could not
  /// read it" and "read it and it is zero" are different facts, and the
  /// checker has to be able to tell them apart.
  Future<_PreflightInputs> _readPreflightInputs(SnipeRule rule) async {
    final sessionResult = await _sessions.ensureSession(rule.account);
    final session = _sessions.sessionFor(rule.account);

    Balance? balance;
    List<Reservation>? holdings;

    if (session != null) {
      try {
        balance = await _client.fetchBalance(session);
      } catch (_) {
        balance = null; // The checker reports this as balanceUnreadable.
      }
      try {
        holdings = await _client.fetchReservations(session);
      } catch (_) {
        holdings = null; // The checker reports this as holdingsUnreadable.
      }
    }

    return _PreflightInputs(
      session: sessionResult,
      balance: balance,
      holdings: holdings,
    );
  }

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
      final inputs = await _readPreflightInputs(rule);
      final session = _sessions.sessionFor(rule.account);

      final hunt = run.hunt;
      final verdict = _preflight.check(
        rule: rule,
        clock: _clock,
        session: inputs.session,
        balance: inputs.balance,
        requiredCredit: hunt?.requiredCreditRial,
        targetDate: hunt?.targetDate,
        holdings: inputs.holdings,
        hunt: hunt,
      );

      if (!verdict.passed) {
        ledger.record(
          at: DateTime.now().toUtc(),
          kind: LedgerEventKind.preflightFailed,
          message: verdict.detail ?? 'پیش‌نیازها برقرار نبود.',
        );
        _finish(run, SnipeState.aborted, verdict.detail ?? 'preflight failed');
        await _listener.onEnded(
          ruleId: rule.id,
          state: SnipeState.aborted,
          reason: verdict.detail ?? 'preflight failed',
        );
        return;
      }

      ledger.record(
        at: _now(),
        kind: LedgerEventKind.preflightPassed,
        message: 'پیش‌نیازها بررسی شد.',
      );

      _transition(run, SnipeState.hunting);

      // --- Hunt ---
      await _hunt(run, session!, inputs.balance);
    } on SnipeCancelled {
      _finish(run, SnipeState.windowExpired, 'stopped by user');
      await _listener.onEnded(
        ruleId: rule.id,
        state: SnipeState.windowExpired,
        reason: 'stopped by user',
      );
    } catch (error) {
      ledger.record(
        at: DateTime.now().toUtc(),
        kind: LedgerEventKind.runEnded,
        message: 'اجرا با خطا پایان یافت: $error',
      );
      _finish(run, SnipeState.aborted, error.toString());
      await _listener.onEnded(
        ruleId: rule.id,
        state: SnipeState.aborted,
        reason: error.toString(),
      );
    } finally {
      // A finished run leaves the registry: otherwise `isRunning` would lie
      // forever and the run would leak. The ledger survives in `_ledgers`.
      _runs.remove(rule.id);
      run.controller.close();
    }
  }

  Future<void> _hunt(_Run run, Session session, Balance? balance) async {
    final rule = run.rule;
    final hunt = run.hunt;
    final policy = _defaultPolicy;
    final breaker = CircuitBreaker(policy.failureThreshold);
    final budget = RequestBudget(hunt?.requestBudget ?? policy.requestBudget);

    while (!run.isCancelled) {
      // Window check each cycle: the window can close mid-hunt.
      final now = _now();
      final clockTime = _clock.isSynced
          ? ClockTime(_clock.portalNow.hour, _clock.portalNow.minute)
          : null;

      if (clockTime != null && !rule.isWithinWindow(clockTime)) {
        run.ledger.record(
          at: now,
          kind: LedgerEventKind.runEnded,
          message: 'بازه زمانی به پایان رسید.',
        );
        _finish(run, SnipeState.windowExpired, 'window closed');
        await _listener.onEnded(
          ruleId: rule.id,
          state: SnipeState.windowExpired,
          reason: 'window closed',
        );
        return;
      }

      if (budget.isExhausted) {
        run.ledger.record(
          at: now,
          kind: LedgerEventKind.runEnded,
          message: 'سهمیه درخواست این اجرا به پایان رسید.',
        );
        _finish(run, SnipeState.windowExpired, 'budget exhausted');
        await _listener.onEnded(
          ruleId: rule.id,
          state: SnipeState.windowExpired,
          reason: 'budget exhausted',
        );
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
          await _listener.onEnded(
            ruleId: rule.id,
            state: SnipeState.aborted,
            reason: 'circuit open',
          );
          return;
        }
      }

      // A completed claim ends the run.
      if (SnipeStateMachine.isTerminal(run.status.state)) return;

      // The interval is measured from the *end* of the previous cycle, not
      // from its start. The wait below is chained after the poll has finished
      // and been parsed, so a slow response cannot overlap the next request.
      //
      // The hunt's rate is a function of the time: peak inside the target
      // meal's distribution window, off-peak outside it.
      final interval = _intervalFor(run, clockTime, breaker.consecutiveFailures);
      await _sleep(interval);
    }
    throw const SnipeCancelled();
  }

  /// The wait before the next poll.
  ///
  /// A hunt uses its configured rate; a plain rule uses the policy's cadence.
  ///
  /// ## The hunt's jitter only ever lengthens the wait
  ///
  /// The policy's jitter is symmetric — 0.8× to 1.2× — because for a rule
  /// nobody configured, the mean is what matters. For a hunt it does not: the
  /// user set a rate, and the rate is a **floor**. A symmetric jitter could
  /// make the hunt poll *faster* than the user asked, which would
  ///
  ///   - undercut the hard floor (a 2-second peak could become 1.6 seconds),
  ///   - break the floor the ban acknowledgement is attached to, and
  ///   - make the projected request count a lie, since the UI prices the
  ///     slider from the nominal interval.
  ///
  /// So the hunt's jitter is one-sided: the wait is the interval or a little
  /// longer, never shorter. The clients still do not synchronise — each one
  /// has its own random offset — so the original reason for jitter survives.
  ///
  /// The hunt's floor is [HuntBounds], not the policy's 20-second hard floor.
  /// The two disagree on purpose: the policy's floor governs a rule that
  /// nobody configured, and the hunt's bounds are the product owner's explicit
  /// decision — 2 seconds in peak, with a ban-risk acknowledgement above it.
  /// The hunt's rate is clamped on construction, so it cannot be out of range
  /// by the time it reaches here.
  Duration _intervalFor(_Run run, ClockTime? clockTime, int consecutiveFailures) {
    final hunt = run.hunt;
    if (hunt == null) {
      return _defaultPolicy.nextInterval(
        consecutiveFailures: consecutiveFailures,
        random: _random,
      );
    }

    final base = clockTime == null
        ? hunt.rate.offPeakInterval
        : hunt.intervalAt(clockTime);

    // A failure backs the hunt off too: when something is wrong, asking less
    // often protects both the portal and the account.
    var interval = base;
    if (consecutiveFailures > 0) {
      final multiplier = 1 << consecutiveFailures;
      final backedOff = base * multiplier;
      interval = backedOff > _defaultPolicy.maxBackoff
          ? _defaultPolicy.maxBackoff
          : backedOff;
    }

    // One-sided jitter: the factor is in [1, jitterMax], never below 1.
    final factor = 1 + _random.nextDouble() * (_defaultPolicy.jitterMax - 1);

    return Duration(
      microseconds: (interval.inMicroseconds * factor).round(),
    );
  }

  /// One poll cycle. Returns false when the poll itself failed.
  ///
  /// Returns true when the poll succeeded, whether or not a match was found —
  /// "found nothing" is a healthy outcome, not a failure, and treating it as one
  /// would trip the circuit breaker on a quiet market.
  Future<bool> _pollOnce(_Run run, Session session, Balance? balance) async {
    final rule = run.rule;
    final hunt = run.hunt;
    final now = _now();

    final BasketPage page;
    try {
      // A hunt reads the basket for its *target date*: the buy page is
      // date-filtered, and the market's listings for another day are not
      // what the hunt is waiting for.
      page = await _client.fetchBasket(
        session,
        cursor: hunt?.targetDate == null ? null : _jalaliOf(hunt!.targetDate!),
      );
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

    // A hunt ranks with its own ranker, which matches on the dish name — the
    // market renumbers option ids, so an id-based match would never fire.
    if (hunt != null) {
      final result = _huntRanker.selectBest(
        config: hunt,
        listings: live,
        maxPriceRial: hunt.maxPriceRial,
      );

      for (final candidate in result.considered) {
        if (candidate.isEligible) continue;
        run.ledger.record(
          at: now,
          kind: LedgerEventKind.skipped,
          message: 'رد شد (${candidate.skipReason?.name}): '
              '${candidate.listing.option.name}',
          listingId: candidate.listing.id,
          simulated: rule.dryRun,
        );
      }

      final best = result.best;
      if (best == null) return true;

      _transition(run, SnipeState.matched);
      run.ledger.record(
        at: now,
        kind: LedgerEventKind.matched,
        message: 'آگهی مناسب پیدا شد: ${best.option.name}، ${best.hall.name}',
        listingId: best.id,
        simulated: rule.dryRun,
      );

      await _claim(run, session, best);
      return true;
    }

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
      await _listener.onEnded(
        ruleId: rule.id,
        state: SnipeState.claimed,
        reason: 'dry run match',
      );
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
        // The purchase is final, so the hunt stops here. Continuing would
        // risk a second, unwanted meal — and a basket purchase cannot be
        // cancelled, so there is no undo for that.
        //
        // The notification is posted *after* the outcome is known, never when
        // the claim is sent: an ambiguous claim must not produce a success
        // notification, because it may not have been a purchase at all.
        await _listener.onClaimed(
          ruleId: rule.id,
          listing: listing,
          reservation: reservation,
        );

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
        await _listener.onClaimed(
          ruleId: rule.id,
          listing: listing,
          reservation: Reservation(
            id: 'reconciled-${listing.id}',
            date: listing.date,
            slot: listing.slot,
            hall: listing.hall,
            option: listing.option,
            state: ReservationState.active,
          ),
        );

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

  /// A civil date as the portal's `yyyy/MM/dd` Jalali string.
  ///
  /// The buy page's date filter takes the portal's own Jalali form, and the
  /// engine must not invent one: a date the page does not recognise silently
  /// returns the wrong rows, which would be read as "no listings" and would
  /// look like a quiet market.
  static String _jalaliOf(DateTime date) {
    final jalali = toJalali(date);
    return '${jalali.year}/${jalali.month.toString().padLeft(2, '0')}/'
        '${jalali.day.toString().padLeft(2, '0')}';
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

/// The reads a pre-flight needs.
class _PreflightInputs {
  const _PreflightInputs({
    required this.session,
    this.balance,
    this.holdings,
  });

  final SessionResult session;

  /// Null when the balance could not be read.
  final Balance? balance;

  /// Null when the holdings could not be read.
  final List<Reservation>? holdings;
}

/// Mutable state for one running rule.
class _Run {
  _Run({required this.rule, required this.status, this.hunt})
      : ledger = SnipeLedger(rule.id);

  final SnipeRule rule;

  /// The hunt configuration, when this run is a hunt.
  final HuntConfig? hunt;

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
