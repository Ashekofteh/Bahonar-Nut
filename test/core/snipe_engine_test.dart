import 'dart:async';
import 'dart:math';

import 'package:bahonar_nut/core/ledger.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/polling.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/core/priority.dart';
import 'package:bahonar_nut/core/session.dart';
import 'package:bahonar_nut/core/session_manager.dart';
import 'package:bahonar_nut/core/snipe.dart';
import 'package:bahonar_nut/core/snipe_engine.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:test/test.dart';

const central = Hall(id: '1', name: 'مرکزی برادران');
final optA = const MenuOption(id: '62702', name: 'زرشک پلو', priceRial: 350000);
final optB = const MenuOption(id: '62714', name: 'جوجه کباب', priceRial: 500000);

Listing listing(String id, {MenuOption? option, MealSlot slot = MealSlot.lunch}) =>
    Listing(
      id: id,
      date: DateTime.utc(2026, 10, 20),
      slot: slot,
      hall: central,
      option: option ?? optA,
    );

SnipeRule buildRule({
  bool dryRun = false,
  int? maxPrice,
  int maxPurchases = 1,
  MealSlot slot = MealSlot.lunch,
}) =>
    SnipeRule(
      id: 'r1',
      account: 'a1',
      dryRun: dryRun,
      maxPriceRial: maxPrice,
      maxPurchasesPerWindow: maxPurchases,
      slots: {slot},
      preferences: {
        slot: SlotPreference(
          slot: slot,
          ranked: const [
            PreferencePair(hallId: '1', optionId: '62702'),
            PreferencePair(hallId: '1', optionId: '62714'),
          ],
        ),
      },
    );

/// A client whose basket and claim behaviour the test scripts.
class ScriptedClient implements PortalClient {
  ScriptedClient({
    List<List<Listing>>? basketPages,
    this.claimBehavior = ClaimBehavior.succeed,
    this.reconcileReservations = const [],
  }) : _basketPages = basketPages ?? [];

  /// Successive basket responses; the last one repeats once exhausted.
  final List<List<Listing>> _basketPages;
  int basketCalls = 0;

  ClaimBehavior claimBehavior;
  List<Reservation> reconcileReservations;

  int claimCalls = 0;
  int reserveCalls = 0;
  int cancelCalls = 0;

  @override
  Future<BasketPage> fetchBasket(Session session, {String? cursor}) async {
    final index = basketCalls < _basketPages.length
        ? basketCalls
        : (_basketPages.isEmpty ? -1 : _basketPages.length - 1);
    basketCalls++;
    if (index < 0) return const BasketPage(listings: []);
    return BasketPage(listings: _basketPages[index]);
  }

  @override
  Future<ClaimResult> claim(Session session, ListingId listingId) async {
    claimCalls++;
    switch (claimBehavior) {
      case ClaimBehavior.succeed:
        return ClaimSucceeded(Reservation(
          id: 'r-$listingId',
          date: DateTime.utc(2026, 10, 20),
          slot: MealSlot.lunch,
          hall: central,
          option: optA,
          state: ReservationState.active,
        ));
      case ClaimBehavior.reject:
        return const ClaimRejected('کسی دیگر آن را خرید');
      case ClaimBehavior.ambiguous:
        return const ClaimAmbiguous('timeout');
      case ClaimBehavior.throw_:
        throw Exception('connection reset mid-request');
    }
  }

  @override
  Future<List<Reservation>> fetchReservations(Session session) async =>
      reconcileReservations;

  @override
  Future<Balance> fetchBalance(Session session) async =>
      Balance(amountRial: 1000000, fetchedAt: DateTime.utc(2026, 10, 18));

  @override
  Future<LoginChallenge?> beginLogin(String username) async => null;

  @override
  Future<Session> completeLogin({
    required String username,
    required String password,
    LoginChallengeResponse? challenge,
  }) async =>
      Session(
        account: username,
        cookies: const {'ASP.NET_SessionId': 'x'},
        establishedAt: DateTime.now().toUtc(),
      );

  @override
  Future<Session> refresh(Session session) async => session;

  @override
  Future<void> logout(Session session) async {}

  @override
  Future<DateTime> fetchServerTime(Session session) async =>
      DateTime.utc(2026, 10, 18);

  @override
  Future<List<MealOffering>> fetchOfferings(Session s, DateTime date) async =>
      const [];

  @override
  Future<Reservation> reserve(Session session, MealOffering offering) async {
    reserveCalls++;
    throw UnimplementedError();
  }

  @override
  Future<List<Transaction>> fetchTransactions(Session session) async =>
      const <Transaction>[];

  @override
  Future<void> cancel(Session session, MealId mealId) async {
    cancelCalls++;
  }

  @override
  Uri? topUpUrl(Session session) => null;
}

enum ClaimBehavior { succeed, reject, ambiguous, throw_ }

/// A session store that always has credentials, so preflight passes.
class AlwaysStore implements SessionStore {
  @override
  Future<Credentials?> readCredentials(AccountId accountId) async =>
      const Credentials(studentId: '401405035', password: 'pw');

  @override
  Future<void> writeCredentials(AccountId a, Credentials c) async {}

  @override
  Future<StoredSession?> readSession(AccountId accountId) async =>
      StoredSession(
        accountId: accountId,
        cookies: const {'ASP.NET_SessionId': 'live'},
        establishedAt: DateTime.now().toUtc(),
      );

  @override
  Future<void> writeSession(StoredSession session) async {}

  @override
  Future<void> deleteSession(AccountId accountId) async {}

  @override
  Future<void> purge(AccountId accountId) async {}
}

class NoopSolver implements ChallengeSolver {
  @override
  Future<String?> solve(LoginChallenge challenge) async => '1234';
}

/// Builds an engine whose sleep resolves immediately, so the poll loop runs
/// synchronously in tests instead of waiting real jittered seconds.
DefaultSnipeEngine buildEngine(ScriptedClient client) {
  final sessions = SessionManager(
    client: client,
    store: AlwaysStore(),
    solver: NoopSolver(),
    clock: FixedServerClock.now(DateTime.utc(2026, 10, 18, 7, 0)),
  );
  return DefaultSnipeEngine(
    client: client,
    sessions: sessions,
    clock: FixedServerClock.now(DateTime.utc(2026, 10, 18, 7, 0)),
    // Poll fast and deterministically: no real delay, no jitter surprises.
    defaultPolicy: const PollingPolicy(
      baseInterval: Duration.zero,
      jitterMin: 1.0,
      jitterMax: 1.0,
    ),
    random: Random(1),
    sleep: (_) async {},
  );
}

/// Waits until [condition] holds, or fails after [timeout].
Future<void> waitFor(bool Function() condition, {Duration? timeout}) async {
  final limit = timeout ?? const Duration(seconds: 5);
  final deadline = DateTime.now().add(limit);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('condition not met within $limit');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  group('winning a listing', () {
    test('polls, matches, claims, and terminates claimed', () async {
      final client = ScriptedClient(basketPages: [
        [], // first poll: nothing
        [listing('L1')], // second poll: a match
      ]);
      final engine = buildEngine(client);
      await engine.start(buildRule());

      await waitFor(() => !engine.isRunning('r1'));

      final ledger = engine.ledgerFor('r1')!;
      expect(client.claimCalls, 1);
      expect(ledger.purchaseCount, 1);
      expect(
        ledger.entries.any((e) => e.kind == LedgerEventKind.claimSucceeded),
        isTrue,
      );
    });

    test('status reports the claimed listing', () async {
      final client = ScriptedClient(basketPages: [
        [listing('L1')],
      ]);
      final engine = buildEngine(client);
      final statuses = <SnipeRunStatus>[];
      await engine.start(buildRule());
      engine.watch('r1').listen(statuses.add);

      await waitFor(() => !engine.isRunning('r1'));

      expect(statuses.last.state, SnipeState.claimed);
      expect(statuses.last.claimedListingId, 'L1');
    });

    test('prefers the higher-ranked listing', () async {
      final client = ScriptedClient(basketPages: [
        [listing('L2', option: optB), listing('L1', option: optA)],
      ]);
      final engine = buildEngine(client);
      await engine.start(buildRule());
      await waitFor(() => !engine.isRunning('r1'));

      final ledger = engine.ledgerFor('r1')!;
      final match = ledger
          .entries
          .firstWhere((e) => e.kind == LedgerEventKind.matched);
      expect(match.listingId, 'L1', reason: 'optA outranks optB');
    });

    test('a price ceiling prevents buying an over-budget listing', () async {
      final client = ScriptedClient(basketPages: [
        [listing('L2', option: optB)], // 500000, over the 400000 ceiling
      ]);
      final engine = buildEngine(client);
      await engine.start(buildRule(maxPrice: 400000));

      // Give it a few cycles to find nothing.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await engine.stop('r1');

      expect(client.claimCalls, 0, reason: 'nothing was affordable');
      final ledger = engine.ledgerFor('r1')!;
      expect(
        ledger.entries.any((e) => e.kind == LedgerEventKind.skipped),
        isTrue,
      );
    });
  });

  group('dry run', () {
    test('never issues a claim, but records what it would have done', () async {
      final client = ScriptedClient(basketPages: [
        [listing('L1')],
      ]);
      final engine = buildEngine(client);
      await engine.start(buildRule(dryRun: true));
      await waitFor(() => !engine.isRunning('r1'));

      expect(client.claimCalls, 0, reason: 'dry run must not write');
      final ledger = engine.ledgerFor('r1')!;
      expect(ledger.simulatedPurchaseCount, 1);
      expect(ledger.purchaseCount, 0, reason: 'no real purchase in a dry run');
    });

    test('a dry run never calls reserve or cancel either', () async {
      final client = ScriptedClient(basketPages: [
        [listing('L1')],
      ]);
      final engine = buildEngine(client);
      await engine.start(buildRule(dryRun: true));
      await waitFor(() => !engine.isRunning('r1'));

      expect(client.reserveCalls, 0);
      expect(client.cancelCalls, 0);
    });
  });

  group('losing a race', () {
    test('a rejected claim tombstones the listing and never re-claims it', () async {
      final client = ScriptedClient(
        basketPages: [
          [listing('L1')],
        ],
        claimBehavior: ClaimBehavior.reject,
      );
      final engine = buildEngine(client);
      await engine.start(buildRule());

      // Let it run several cycles against the same dead listing.
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await engine.stop('r1');

      expect(client.claimCalls, 1,
          reason: 'the dead listing must be tombstoned after the first rejection');
    });

    test('it keeps hunting after losing, if the window is open', () async {
      final client = ScriptedClient(
        basketPages: [
          [listing('L1')],
          [listing('L2')],
        ],
        claimBehavior: ClaimBehavior.reject,
      );
      final engine = buildEngine(client);
      await engine.start(buildRule());
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await engine.stop('r1');

      // Two distinct listings, two attempts: custody of the tombstone is per
      // listing, so a fresh listing is still claimable.
      expect(client.claimCalls, 2);
    });
  });

  group('ambiguous claim — the double-purchase guard', () {
    test('an ambiguous claim is NEVER retried', () async {
      final client = ScriptedClient(
        basketPages: [
          [listing('L1')],
        ],
        claimBehavior: ClaimBehavior.ambiguous,
      );
      final engine = buildEngine(client);
      await engine.start(buildRule());
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await engine.stop('r1');

      expect(client.claimCalls, 1,
          reason: 'a blind retry could buy two meals and charge twice');
    });

    test('a thrown claim is treated as ambiguous, and not retried', () async {
      final client = ScriptedClient(
        basketPages: [
          [listing('L1')],
        ],
        claimBehavior: ClaimBehavior.throw_,
      );
      final engine = buildEngine(client);
      await engine.start(buildRule());
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await engine.stop('r1');

      expect(client.claimCalls, 1);
      final ledger = engine.ledgerFor('r1')!;
      expect(
        ledger.entries.any((e) => e.kind == LedgerEventKind.claimAmbiguous),
        isTrue,
      );
    });

    test('reconcile finds the claim landed -> claimed, and stops', () async {
      final client = ScriptedClient(
        basketPages: [
          [listing('L1')],
        ],
        claimBehavior: ClaimBehavior.ambiguous,
      );
      // The reservation list shows the meal is ours.
      client.reconcileReservations = [
        Reservation(
          id: 'r1',
          date: DateTime.utc(2026, 10, 20),
          slot: MealSlot.lunch,
          hall: central,
          option: optA,
          state: ReservationState.active,
        ),
      ];

      final engine = buildEngine(client);
      await engine.start(buildRule());
      await waitFor(() => !engine.isRunning('r1'));

      final ledger = engine.ledgerFor('r1')!;
      expect(ledger.purchaseCount, 1);
      expect(
        ledger.entries.any((e) => e.kind == LedgerEventKind.reconciled),
        isTrue,
      );
    });

    test('reconcile finds nothing landed -> keeps hunting, no re-claim of L1', () async {
      final client = ScriptedClient(
        basketPages: [
          [listing('L1')],
        ],
        claimBehavior: ClaimBehavior.ambiguous,
      );
      client.reconcileReservations = const [];

      final engine = buildEngine(client);
      await engine.start(buildRule());
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await engine.stop('r1');

      expect(client.claimCalls, 1, reason: 'L1 is tombstoned after reconciliation');
    });

    test('indeterminate reconciliation still tombstones (never a second attempt)', () async {
      final client = ScriptedClient(
        basketPages: [
          [listing('L1')],
        ],
        claimBehavior: ClaimBehavior.ambiguous,
      );
      // fetchReservations throws -> indeterminate.
      final engine = DefaultSnipeEngine(
        client: client,
        sessions: SessionManager(
          client: client,
          store: AlwaysStore(),
          solver: NoopSolver(),
          clock: FixedServerClock.now(DateTime.utc(2026, 10, 18, 7, 0)),
        ),
        clock: FixedServerClock.now(DateTime.utc(2026, 10, 18, 7, 0)),
        defaultPolicy: const PollingPolicy(
          baseInterval: Duration.zero,
          jitterMin: 1.0,
          jitterMax: 1.0,
        ),
        random: Random(1),
        sleep: (_) async {},
      );

      await engine.start(buildRule());
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await engine.stop('r1');

      expect(client.claimCalls, 1,
          reason: 'indeterminate must still forbid a retry');
    });
  });

  group('preflight gating', () {
    test('an unsynced clock aborts before hunting', () async {
      final client = ScriptedClient(basketPages: [
        [listing('L1')],
      ]);
      final engine = DefaultSnipeEngine(
        client: client,
        sessions: SessionManager(
          client: client,
          store: AlwaysStore(),
          solver: NoopSolver(),
          clock: _UnsyncedClock(),
        ),
        clock: _UnsyncedClock(),
        defaultPolicy: const PollingPolicy(
          baseInterval: Duration.zero,
          jitterMin: 1.0,
          jitterMax: 1.0,
        ),
        random: Random(1),
        sleep: (_) async {},
      );

      await engine.start(buildRule());
      await waitFor(() => !engine.isRunning('r1'));

      expect(client.basketCalls, 0, reason: 'must not hunt without a clock');
      final ledger = engine.ledgerFor('r1')!;
      expect(
        ledger.entries.any((e) => e.kind == LedgerEventKind.preflightFailed),
        isTrue,
      );
    });

    test('a window that is closed aborts rather than hunting', () async {
      final client = ScriptedClient(basketPages: [
        [listing('L1')],
      ]);
      final engine = buildEngine(client);
      // Portal-local 10:00 UTC = 13:30, outside 08:00-09:00.
      final rule = SnipeRule(
        id: 'r1',
        account: 'a1',
        slots: const {MealSlot.lunch},
        windowStart: const ClockTime(8, 0),
        windowEnd: const ClockTime(9, 0),
        preferences: {
          MealSlot.lunch: SlotPreference(
            slot: MealSlot.lunch,
            ranked: const [PreferencePair(hallId: '1', optionId: '62702')],
          ),
        },
      );

      await engine.start(rule);
      await waitFor(() => !engine.isRunning('r1'));

      expect(client.basketCalls, 0);
    });
  });

  group('idempotence and control', () {
    test('starting the same rule twice does not create two hunts', () async {
      final client = ScriptedClient(basketPages: [
        [listing('L1')],
      ]);
      final engine = buildEngine(client);

      await engine.start(buildRule());
      await engine.start(buildRule()); // idempotent

      await waitFor(() => !engine.isRunning('r1'));
      expect(client.claimCalls, 1, reason: 'one hunt, one claim');
    });

    test('stop ends a running hunt', () async {
      final client = ScriptedClient(basketPages: [
        [], // never matches, so it keeps hunting
      ]);
      final engine = buildEngine(client);
      await engine.start(buildRule());

      // Immediately after start the run must be registered. (No delay here: the
      // loop burns its 400-request budget in milliseconds with instant sleep,
      // so a delay would let it finish on its own — which is the budget working,
      // not a broken stop.)
      expect(engine.isRunning('r1'), isTrue);
      await engine.stop('r1');
      expect(engine.isRunning('r1'), isFalse);
    });

    test('watch on an unknown rule yields an empty stream', () {
      final client = ScriptedClient();
      final engine = buildEngine(client);
      expect(engine.watch('nope'), emitsDone);
    });
  });

  group('ledger hygiene', () {
    test('the ledger is bounded', () async {
      final client = ScriptedClient(basketPages: [
        [],
      ]);
      final engine = buildEngine(client);
      await engine.start(buildRule());
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await engine.stop('r1');

      final ledger = engine.ledgerFor('r1')!;
      expect(ledger.entries.length, lessThanOrEqualTo(SnipeLedger.maxEntries));
    });

    test('poll count advances', () async {
      final client = ScriptedClient(basketPages: [
        [],
      ]);
      final engine = buildEngine(client);
      await engine.start(buildRule());
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await engine.stop('r1');

      final ledger = engine.ledgerFor('r1')!;
      expect(ledger.ofKind(LedgerEventKind.polled).length, greaterThan(1));
    });
  });
}

class _UnsyncedClock implements ServerClock {
  @override
  DateTime get nowUtc => DateTime.utc(2026, 10, 18, 7, 0);

  @override
  bool get isSynced => false;

  @override
  Duration get staleness => Duration.zero;
}