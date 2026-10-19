/// Preconditions checked before a hunt begins, and reconciliation after an
/// ambiguous claim.
///
/// Both exist for the same reason: the moment a hunt is live is the worst time
/// to discover a problem, and the moment a claim is in flight is the worst time
/// to guess. Preflight moves discovery to a point where the user can still act;
/// reconciliation replaces a dangerous guess with a fact.
library;

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

  /// The hunt window has already closed.
  windowClosed,

  /// The portal is reachable but returned a balance we could not read.
  balanceUnreadable,

  /// The balance is below the cheapest option the rule would consider.
  insufficientFunds,
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
  /// [balance] is null when the balance could not be read. [cheapestConsidered]
  /// is the lowest price among the rule's ranked, non-vetoed options, or null
  /// when the rule has no price ceiling and funds therefore cannot be judged.
  PreflightResult check({
    required SnipeRule rule,
    required ServerClock clock,
    required SessionResult session,
    Balance? balance,
    int? cheapestConsidered,
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
    final hasAnyPreference = rule.preferences.values
        .any((pref) => pref.ranked.any((pair) => !pair.rejected));
    if (!hasAnyPreference) {
      failures.add(PreflightFailure.noPreferences);
      notes.add('هیچ گزینه‌ای برای این وعده‌ها اولویت‌بندی نشده است.');
    }

    // Window check, using portal-local time.
    if (clock.isSynced) {
      final portalNow = clock.portalNow;
      final clockTime = ClockTime(portalNow.hour, portalNow.minute);
      if (!rule.isWithinWindow(clockTime)) {
        failures.add(PreflightFailure.windowClosed);
        notes.add('بازه زمانی این قانون فعال نیست.');
      }
    }

    // Funds last: it needs a network read, so it is the most expensive check and
    // the one most likely to be skipped when earlier checks already failed.
    if (failures.isEmpty && balance == null && cheapestConsidered != null) {
      failures.add(PreflightFailure.balanceUnreadable);
      notes.add('موجودی حساب خوانده نشد.');
    } else if (balance != null &&
        cheapestConsidered != null &&
        balance.amountRial < cheapestConsidered) {
      failures.add(PreflightFailure.insufficientFunds);
      notes.add('موجودی برای خرید کافی نیست.');
    }

    if (failures.isEmpty) return const PreflightResult.passed();
    return PreflightResult.failed(failures, notes.join(' '));
  }
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
/// A blind retry can buy two meals and charge twice. Instead, re-fetch the
/// reservation list and ask whether the meal is now ours.
class ClaimReconciler {
  const ClaimReconciler();

  /// Determines whether [listing] became a reservation.
  ///
  /// Matching is by slot, date and hall rather than by listing ID, because the
  /// portal assigns a *new* reservation identifier — the listing ID does not
  /// survive into the reservation. Matching on the listing ID would therefore
  /// always conclude "not claimed" and invite the double purchase.
  Future<ReconciliationOutcome> reconcile({
    required PortalClient client,
    required Session session,
    required Listing listing,
  }) async {
    try {
      final reservations = await client.fetchReservations(session);
      final matched = reservations.any(
        (r) =>
            r.slot == listing.slot &&
            r.state == ReservationState.active &&
            _sameDate(r.date, listing.date) &&
            r.hall.id == listing.hall.id,
      );
      return matched
          ? ReconciliationOutcome.claimed
          : ReconciliationOutcome.notClaimed;
    } catch (_) {
      // The re-read failed. We genuinely do not know, and inventing an answer
      // here would be worse than admitting ignorance.
      return ReconciliationOutcome.indeterminate;
    }
  }

  static bool _sameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}