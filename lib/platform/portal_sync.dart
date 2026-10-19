/// Reading the portal and refreshing the local mirror.
///
/// The local store is what the reminders read, so keeping it fresh is the
/// bridge between "the portal knows something" and "the app knows something".
///
/// ## Why the sync is explicit rather than automatic
///
/// Every portal read costs a request, and a request pattern is the thing most
/// likely to get an account flagged. So the sync happens:
///   * when the user asks for it (pull to refresh), and
///   * when the app does something itself (a booking, a purchase, a cancel).
///
/// It is never a background poll. The sniping engine polls the **basket**, not
/// the account, and only inside a hunting window.
library;

import '../core/local_meal_store.dart';
import '../core/meal_invariant.dart';
import '../core/models.dart';
import '../core/portal.dart';
import '../core/session.dart';
import '../core/session_manager.dart';

/// The outcome of a sync for one account.
class AccountSyncResult {
  const AccountSyncResult({
    required this.accountId,
    required this.ok,
    this.balanceRial,
    this.reservations = const [],
    this.profileName,
    this.error,
  });

  final AccountId accountId;
  final bool ok;
  final int? balanceRial;
  final List<Reservation> reservations;

  /// The student's real name, as the portal knows it. Null when the account
  /// could not be read.
  final String? profileName;

  final String? error;

  @override
  String toString() => 'AccountSyncResult($accountId, ok=$ok'
      '${error == null ? "" : ", error=$error"})';
}

/// Reads the portal for a set of accounts and refreshes the local mirror.
class PortalSync {
  PortalSync({
    required this.client,
    required this.sessions,
    required this.mealStore,
  });

  final PortalClient client;
  final SessionManager sessions;
  final LocalMealStore mealStore;

  /// Reads one account.
  ///
  /// A failure is reported, not thrown: the user may have several accounts and
  /// one of them may be misconfigured, and the others should still work.
  Future<AccountSyncResult> sync(AccountId accountId) async {
    final sessionResult = await sessions.ensureSession(accountId);
    if (sessionResult is! SessionReady) {
      return AccountSyncResult(
        accountId: accountId,
        ok: false,
        error: sessionResult is SessionUnavailable
            ? sessionResult.reason
            : 'ورود ناموفق بود.',
      );
    }

    final session = sessionResult.session;

    try {
      final balance = await client.fetchBalance(session);
      final reservations = await client.fetchReservations(session);

      // Replace this account's meals in the local mirror, so a meal the portal
      // no longer lists does not linger in the reminders.
      final others = mealStore
          .all
          .where((m) => m.accountId != accountId)
          .toList();
      final refreshed = <StoredMeal>[
        ...others,
        for (final reservation in reservations)
          StoredMeal(
            accountId: accountId,
            date: reservation.date,
            slot: reservation.slot,
            source: MealSource.weeklyReservation,
            capturedAt: DateTime.now().toUtc(),
            optionId: reservation.option.id,
            dishName: reservation.option.name,
            hallName: reservation.hall.name,
            priceRial: reservation.option.priceRial,
          ),
      ];
      mealStore.replaceAll(refreshed);

      return AccountSyncResult(
        accountId: accountId,
        ok: true,
        balanceRial: balance.amountRial,
        reservations: reservations,
      );
    } catch (e) {
      return AccountSyncResult(
        accountId: accountId,
        ok: false,
        error: '$e',
      );
    }
  }

  /// Reads every account, one after another.
  ///
  /// Sequential, not parallel: the portal is a shared resource and a burst of
  /// logins from one device looks like an attack. The requests are seconds
  /// apart and few.
  Future<List<AccountSyncResult>> syncAll(
    Iterable<AccountId> accountIds,
  ) async {
    final out = <AccountSyncResult>[];
    for (final accountId in accountIds) {
      out.add(await sync(accountId));
    }
    return out;
  }
}
