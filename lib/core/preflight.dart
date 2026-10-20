/// Preconditions checked before a hunt begins, and reconciliation after an
/// ambiguous claim.
///
/// Both exist for the same reason: the moment a hunt is live is the worst time
/// to discover a problem, and the moment a claim is in flight is the worst time
/// to guess. Preflight moves discovery to a point where the user can still act;
/// reconciliation replaces a dangerous guess with a fact.
library;

import 'hunt_config.dart';
import 'models.dart';
import 'portal.dart';
import 'session.dart';
import 'snipe.dart';
import 'time.dart';

/// Why preflight refused to start.
enum PreflightFailure {
  /// The portal clock is not synced, so the cutoff boundary is unknown.
  clockUnsynced,

  /// No usable session could be established for the account.
  noSession,

  /// The ruleset selects nothing this rule's slots could ever match.
  noPreferences,

  /// The portal is reachable but returned a balance we could not read.
  balanceUnreadable,

  /// The balance cannot cover the meals on the priority list.
  insufficientFunds,

  /// The account already holds a meal for the target date and slot.
  ///
  /// The one-meal invariant, checked before the hunt starts rather than at the
  /// moment of claiming. A basket purchase is irreversible, so buying a second
  /// meal for a slot the student already has is money spent on food that can
  /// neither be collected nor cancelled.
  alreadyBooked,

  /// The account's holdings could not be read, so the invariant cannot be
  /// checked.
  ///
  /// A refusal rather than a pass: starting a hunt without knowing whether the
  /// slot is already filled is exactly how a double purchase happens.
  holdingsUnreadable,
}

/// The verdict of a preflight check.
class PreflightResult {
  /// Passed.
  const PreflightResult.passed()
      : failures = const [],
        detail = null;

  /// Failed, with every reason rather than just the first.
  ///
  /// All reasons are collected because fixing one problem only to be stopped by
  /// the next is a poor experience when the fixes are independent (a top-up and
  /// a re-login, say).
  const PreflightResult.failed(this.failures, [this.detail]);

  final List<PreflightFailure> failures;
  final String? detail;

  bool get passed => failures.isEmpty;

  @override
  String toString() =>
      passed ? 'PreflightResult.passed' : 'PreflightResult.failed($failures)';
}

/// Runs preconditions for a rule.
class PreflightChecker {
  const PreflightChecker();

  /// Checks everything that must hold before a hunt may begin.
  ///
  /// [balance] is null when the balance could not be read. [requiredCredit] is
  /// the total the rule's priority list would cost, or null when the rule has
  /// no price ceiling and funds therefore cannot be judged.
  ///
  /// [holdings] is what the account already holds on the target date, or null
  /// when it could not be read.
  ///
  /// [hunt] is the hunt configuration, when the rule is a hunt. It supplies
  /// the "is anything wanted at all" answer, because a hunt's priority list is
  /// a list of *dish names* and an optional list of halls — not the rule's
  /// `(hall, option)` pairs, which the hunt's own ranker does not use.
  PreflightResult check({
    required SnipeRule rule,
    required ServerClock clock,
    required SessionResult session,
    Balance? balance,
    int? requiredCredit,
    DateTime? targetDate,
    List<Reservation>? holdings,
    HuntConfig? hunt,
    DateTime? nowUtc,
  }) {
    final failures = <PreflightFailure>[];
    final notes = <String>[];

    // Clock first: without a trustworthy time every other judgement is guesswork.
    if (!clock.isSynced) {
      failures.add(PreflightFailure.clockUnsynced);
      notes.add('ساعت سرور همگام نشده است.');
    }

    if (session is! SessionReady) {
      failures.add(PreflightFailure.noSession);
      if (session is SessionUnavailable) {
        notes.add(session.reason);
      }
    }

    // A rule that can never match anything is a configuration error, not a
    // runtime one, but it is still better surfaced here than as a silent no-op
    // hunt that polls for hours and buys nothing.
    //
    // A hunt is judged on its own priority list: a hunt that names no dish
    // wants nothing, and a hunt that names a dish wants it in whatever hall
    // the market offers. The rule's `(hall, option)` pairs are not the
    // hunt's question — the hunt's ranker matches on the dish name, because
    // the market renumbers option ids.
    final hasAnyPreference = hunt != null
        ? hunt.dishPriority.isNotEmpty
        : rule.preferences.values
            .any((pref) => pref.ranked.any((pair) => !pair.rejected));
    if (!hasAnyPreference) {
      failures.add(PreflightFailure.noPreferences);
      notes.add('هیچ گزینه‌ای برای این وعده‌ها اولویت‌بندی نشده است.');
    }

    // The window is deliberately NOT checked here.
    //
    // The spec's pre-flight is a list of *refusals*: conditions where starting
    // the hunt would spend money on the wrong thing — the account already holds
    // the meal, or the credit does not cover the priority list. A closed
    // window is not on that list, because it is not a mistake: a hunt set up in
    // the morning for the evening window is the normal case, and refusing it
    // would make the feature unusable for every user who configures it ahead
    // of time.
    //
    // Instead the engine *waits*: outside the window it does not poll at all,
    // and starts when the window opens. That is the spec's behaviour, and it
    // is also the safer one — the alternative (refusing) would push the user
    // to start the hunt at 16:30 by hand, and a hunt started at the buzzer is
    // a hunt that has not yet established its session.

    // The one-meal invariant, checked up front rather than at claim time.
    //
    // A basket purchase is irreversible, so a hunt that starts on a slot the
    // student already holds would buy a second meal that can neither be
    // collected nor cancelled. Checking it here costs one read; discovering it
    // after a purchase costs real money.
    if (targetDate != null && holdings == null) {
      failures.add(PreflightFailure.holdingsUnreadable);
      notes.add('وضعیت رزروهای فعلی خوانده نشد.');
    } else if (targetDate != null && holdings != null) {
      // The slots the hunt covers: the hunt's own target slot, or the rule's
      // slots when there is no hunt configuration.
      final slots = hunt?.targetSlot != null
          ? {hunt!.targetSlot}
          : rule.slots;
      final held = holdings.any((r) =>
          r.state == ReservationState.active &&
          _sameDate(r.date, targetDate) &&
          slots.contains(r.slot));
      if (held) {
        failures.add(PreflightFailure.alreadyBooked);
        notes.add('برای این تاریخ و وعده، غذای دیگری در حساب شما ثبت شده است.');
      }
    }

    // Funds last: it needs a network read, so it is the most expensive check and
    // the one most likely to be skipped when earlier checks already failed.
    if (failures.isEmpty && balance == null && requiredCredit != null) {
      failures.add(PreflightFailure.balanceUnreadable);
      notes.add('موجودی حساب خوانده نشد.');
    } else if (balance != null &&
        requiredCredit != null &&
        balance.amountRial < requiredCredit) {
      failures.add(PreflightFailure.insufficientFunds);
      notes.add('موجودی برای خرید کافی نیست.');
    }

    if (failures.isEmpty) return const PreflightResult.passed();
    return PreflightResult.failed(failures, notes.join(' '));
  }

  static bool _sameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

/// What reconciliation concluded about an ambiguous claim.
enum ReconciliationOutcome {
  /// The claim did land: the account now holds the reservation.
  claimed,

  /// The claim did not land: the listing is not ours.
  notClaimed,

  /// Still unknown, because the re-read also failed.
  ///
  /// The safe answer. The caller must tombstone the listing and not retry,
  /// because a second claim on a listing that might already be ours is the
  /// double-purchase this whole path exists to prevent.
  indeterminate,
}

/// Resolves an ambiguous claim by re-reading ground truth.
///
/// The rule this enforces, from the spec: **never retry an ambiguous claim.**
/// A blind retry can buy two meals and charge twice. Instead, re-read the only
/// page that knows and ask whether the meal is now ours.
///
/// ## Why the buy page, and not the reservation grid
///
/// A basket purchase does **not** appear in the weekly reservation grid —
/// verified by a live purchase (2026-10-19), where the grids were byte-for-byte
/// identical before and after. It appears only in the transaction ledger and as
/// a held row on the buy page itself.
///
/// So a reconciler that re-read the reservation grid would conclude
/// `notClaimed` for every *successful* basket purchase, and the engine would
/// hunt on into a second, irreversible one. That is the exact failure this
/// class exists to prevent, so it reads the buy page.
class ClaimReconciler {
  const ClaimReconciler();

  /// Determines whether [listing] became a held meal.
  ///
  /// [client] must support [PortalClient.holdingsOnBuyPage]; the adapter
  /// reports what the buy page says about the listing's row.
  Future<ReconciliationOutcome> reconcile({
    required PortalClient client,
    required Session session,
    required Listing listing,
  }) async {
    try {
      final hold = await client.holdingsOnBuyPage(
        session,
        date: listing.date,
        optionId: listing.option.id,
      );

      // No row at all means the portal no longer shows this listing. It could
      // have been sold to someone else or withdrawn — either way it is not
      // ours, and the caller must not retry it.
      if (hold == null) return ReconciliationOutcome.notClaimed;

      return hold.isHeld
          ? ReconciliationOutcome.claimed
          : ReconciliationOutcome.notClaimed;
    } catch (_) {
      // The re-read failed. We genuinely do not know, and inventing an answer
      // here would be worse than admitting ignorance.
      return ReconciliationOutcome.indeterminate;
    }
  }
}