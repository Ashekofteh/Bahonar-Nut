import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/core/preflight.dart';
import 'package:bahonar_nut/core/priority.dart';
import 'package:bahonar_nut/core/session.dart';
import 'package:bahonar_nut/core/snipe.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:test/test.dart';

const central = Hall(id: '1', name: 'مرکزی برادران');

SlotPreference lunchPref() => SlotPreference(
      slot: MealSlot.lunch,
      ranked: const [
        PreferencePair(hallId: '1', optionId: '62702'),
      ],
    );

SnipeRule ruleWith({
  Map<MealSlot, SlotPreference>? prefs,
  ClockTime start = const ClockTime(0, 0),
  ClockTime end = const ClockTime(23, 59),
}) =>
    SnipeRule(
      id: 'r1',
      account: 'a1',
      preferences: prefs ?? {MealSlot.lunch: lunchPref()},
      windowStart: start,
      windowEnd: end,
    );

SessionReady readySession() => SessionReady(
      session: Session(
        account: 'a1',
        cookies: const {'ASP.NET_SessionId': 'x'},
        establishedAt: DateTime.utc(2026, 10, 18),
      ),
      wasReused: true,
    );

void main() {
  const checker = PreflightChecker();
  // Pre-deadline, mid-morning portal-local.
  final clock = FixedServerClock.now(DateTime.utc(2026, 10, 18, 7, 0));

  group('happy path', () {
    test('passes with a synced clock, a session, preferences and funds', () {
      final result = checker.check(
        rule: ruleWith(),
        clock: clock,
        session: readySession(),
        balance: Balance(amountRial: 500000, fetchedAt: DateTime.utc(2026, 10, 18)),
        cheapestConsidered: 350000,
      );
      expect(result.passed, isTrue);
    });

    test('passes when no price ceiling means funds cannot be judged', () {
      final result = checker.check(
        rule: ruleWith(),
        clock: clock,
        session: readySession(),
        balance: null,
        cheapestConsidered: null,
      );
      expect(result.passed, isTrue);
    });
  });

  group('each precondition fails distinctly', () {
    test('unsynced clock', () {
      final result = checker.check(
        rule: ruleWith(),
        clock: _UnsyncedClock(),
        session: readySession(),
      );
      expect(result.passed, isFalse);
      expect(result.failures, contains(PreflightFailure.clockUnsynced));
    });

    test('no session', () {
      final result = checker.check(
        rule: ruleWith(),
        clock: clock,
        session: const SessionUnavailable(
          reason: 'no creds',
          cause: SessionFailureCause.noCredentials,
        ),
      );
      expect(result.failures, contains(PreflightFailure.noSession));
    });

    test('no preferences configured', () {
      final result = checker.check(
        rule: ruleWith(prefs: const {}),
        clock: clock,
        session: readySession(),
      );
      expect(result.failures, contains(PreflightFailure.noPreferences));
    });

    test('a rule whose only preference is vetoed counts as no preferences', () {
      final vetoed = SlotPreference(
        slot: MealSlot.lunch,
        ranked: const [
          PreferencePair(hallId: '1', optionId: '62702', rejected: true),
        ],
      );
      final result = checker.check(
        rule: ruleWith(prefs: {MealSlot.lunch: vetoed}),
        clock: clock,
        session: readySession(),
      );
      expect(result.failures, contains(PreflightFailure.noPreferences));
    });

    test('window closed', () {
      // Portal-local 10:00 UTC+3:30 = 13:30, outside an 08:00-09:00 window.
      final result = checker.check(
        rule: ruleWith(
          start: const ClockTime(8, 0),
          end: const ClockTime(9, 0),
        ),
        clock: clock,
        session: readySession(),
      );
      expect(result.failures, contains(PreflightFailure.windowClosed));
    });

    test('insufficient funds', () {
      final result = checker.check(
        rule: ruleWith(),
        clock: clock,
        session: readySession(),
        balance: Balance(amountRial: 100000, fetchedAt: DateTime.utc(2026, 10, 18)),
        cheapestConsidered: 350000,
      );
      expect(result.failures, contains(PreflightFailure.insufficientFunds));
    });

    test('unreadable balance', () {
      final result = checker.check(
        rule: ruleWith(),
        clock: clock,
        session: readySession(),
        balance: null,
        cheapestConsidered: 350000,
      );
      expect(result.failures, contains(PreflightFailure.balanceUnreadable));
    });
  });

  group('failures accumulate rather than short-circuiting', () {
    test('reports both an unsynced clock and a missing session', () {
      final result = checker.check(
        rule: ruleWith(),
        clock: _UnsyncedClock(),
        session: const SessionUnavailable(
          reason: 'x',
          cause: SessionFailureCause.noCredentials,
        ),
      );
      // Both are independent problems with independent fixes.
      expect(result.failures, contains(PreflightFailure.clockUnsynced));
      expect(result.failures, contains(PreflightFailure.noSession));
    });

    test('carries a readable explanation', () {
      final result = checker.check(
        rule: ruleWith(),
        clock: _UnsyncedClock(),
        session: readySession(),
      );
      expect(result.detail, isNotNull);
      expect(result.detail, isNotEmpty);
    });
  });

  group('funds boundary', () {
    test('exactly enough passes', () {
      final result = checker.check(
        rule: ruleWith(),
        clock: clock,
        session: readySession(),
        balance: Balance(amountRial: 350000, fetchedAt: DateTime.utc(2026, 10, 18)),
        cheapestConsidered: 350000,
      );
      expect(result.passed, isTrue);
    });

    test('one rial short fails', () {
      final result = checker.check(
        rule: ruleWith(),
        clock: clock,
        session: readySession(),
        balance: Balance(amountRial: 349999, fetchedAt: DateTime.utc(2026, 10, 18)),
        cheapestConsidered: 350000,
      );
      expect(result.failures, contains(PreflightFailure.insufficientFunds));
    });
  });

  group('ClaimReconciler', () {
    final listing = Listing(
      id: 'L1',
      date: DateTime.utc(2026, 10, 20),
      slot: MealSlot.lunch,
      hall: central,
      option: const MenuOption(id: 'o1', name: 'dish', priceRial: 350000),
    );

    test('concludes claimed when the slot is now ours', () async {
      final client = _ReconClient(reservations: [
        Reservation(
          id: 'r1',
          date: DateTime.utc(2026, 10, 20),
          slot: MealSlot.lunch,
          hall: central,
          option: const MenuOption(id: 'o1', name: 'dish', priceRial: 350000),
          state: ReservationState.active,
        ),
      ]);
      final outcome = await const ClaimReconciler().reconcile(
        client: client,
        session: _session(),
        listing: listing,
      );
      expect(outcome, ReconciliationOutcome.claimed);
    });

    test('concludes notClaimed when the slot is absent', () async {
      final client = _ReconClient(reservations: const []);
      final outcome = await const ClaimReconciler().reconcile(
        client: client,
        session: _session(),
        listing: listing,
      );
      expect(outcome, ReconciliationOutcome.notClaimed);
    });

    test('matches on slot/date/hall, NOT on listing id', () async {
      // The portal assigns a fresh reservation id, so an id-based match would
      // always conclude "not claimed" and invite a double purchase.
      final client = _ReconClient(reservations: [
        Reservation(
          id: 'completely-different-id',
          date: DateTime.utc(2026, 10, 20),
          slot: MealSlot.lunch,
          hall: central,
          option: const MenuOption(id: 'o1', name: 'dish', priceRial: 350000),
          state: ReservationState.active,
        ),
      ]);
      final outcome = await const ClaimReconciler().reconcile(
        client: client,
        session: _session(),
        listing: listing,
      );
      expect(outcome, ReconciliationOutcome.claimed);
    });

    test('a cancelled reservation does not count as claimed', () async {
      final client = _ReconClient(reservations: [
        Reservation(
          id: 'r1',
          date: DateTime.utc(2026, 10, 20),
          slot: MealSlot.lunch,
          hall: central,
          option: const MenuOption(id: 'o1', name: 'dish', priceRial: 350000),
          state: ReservationState.cancelled,
        ),
      ]);
      final outcome = await const ClaimReconciler().reconcile(
        client: client,
        session: _session(),
        listing: listing,
      );
      expect(outcome, ReconciliationOutcome.notClaimed);
    });

    test('concludes indeterminate when the re-read fails', () async {
      final client = _ReconClient(throwOnRead: true);
      final outcome = await const ClaimReconciler().reconcile(
        client: client,
        session: _session(),
        listing: listing,
      );
      expect(outcome, ReconciliationOutcome.indeterminate);
    });

    test('a different hall does not count as the same meal', () async {
      final client = _ReconClient(reservations: [
        Reservation(
          id: 'r1',
          date: DateTime.utc(2026, 10, 20),
          slot: MealSlot.lunch,
          hall: const Hall(id: '2', name: 'فنی برادران'),
          option: const MenuOption(id: 'o1', name: 'dish', priceRial: 350000),
          state: ReservationState.active,
        ),
      ]);
      final outcome = await const ClaimReconciler().reconcile(
        client: client,
        session: _session(),
        listing: listing,
      );
      expect(outcome, ReconciliationOutcome.notClaimed);
    });
  });
}

Session _session() => Session(
      account: 'a1',
      cookies: const {'ASP.NET_SessionId': 'x'},
      establishedAt: DateTime.utc(2026, 10, 18),
    );

/// Minimal client that only serves [fetchReservations].
class _ReconClient implements PortalClient {
  _ReconClient({this.reservations = const [], this.throwOnRead = false});

  final List<Reservation> reservations;
  final bool throwOnRead;

  @override
  Future<List<Reservation>> fetchReservations(Session session) async {
    if (throwOnRead) throw Exception('network down');
    return reservations;
  }

  @override
  Future<List<Transaction>> fetchTransactions(Session session) async =>
      const <Transaction>[];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not used');
}

class _UnsyncedClock implements ServerClock {
  @override
  DateTime get nowUtc => DateTime.utc(2026, 10, 18);

  @override
  bool get isSynced => false;

  @override
  Duration get staleness => Duration.zero;
}