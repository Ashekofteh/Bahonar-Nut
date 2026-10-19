import 'dart:async';
import 'dart:math';

import 'package:bahonar_nut/core/hunt_config.dart';
import 'package:bahonar_nut/core/ledger.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/core/session.dart';
import 'package:bahonar_nut/core/session_manager.dart';
import 'package:bahonar_nut/core/snipe.dart';
import 'package:bahonar_nut/core/snipe_engine.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:test/test.dart';

const central = Hall(id: '1', name: 'مرکزی برادران');

/// The portal-local instant of [utc] plus the offset, as a [ClockTime].
ClockTime portalTime(DateTime utc) {
  final local = utc.add(ServerClock.portalUtcOffset);
  return ClockTime(local.hour, local.minute);
}

/// A market listing, with the id the *market* uses rather than the official
/// menu's — the market renumbers ids, so the hunt must match on the name.
Listing marketListing({
  required String optionId,
  required String name,
  int priceRial = 350000,
  Hall hall = central,
  MealSlot slot = MealSlot.dinner,
}) =>
    Listing.composite(
      date: DateTime.utc(2026, 10, 28),
      slot: slot,
      hall: hall,
      option: MenuOption(id: optionId, name: name, priceRial: priceRial),
    );

HuntConfig huntConfig({
  List<HuntDish>? dishes,
  List<HuntHall>? halls,
  MealSlot slot = MealSlot.dinner,
  HuntRate? rate,
  DateTime? targetDate,
  int requestBudget = 400,
  ClockTime? windowStart,
  ClockTime? windowEnd,
}) =>
    HuntConfig(
      targetSlot: slot,
      dishPriority: dishes ??
          [HuntDish(optionId: '62742', name: 'لوبیا پلو', priceRial: 350000)],
      hallPriority: halls ?? const [],
      rate: rate ??
          HuntRate(
            peakInterval: const Duration(seconds: 10),
            offPeakInterval: const Duration(minutes: 15),
          ),
      targetDate: targetDate ?? DateTime.utc(2026, 10, 28),
      requestBudget: requestBudget,
      windowStart: windowStart ?? const ClockTime(16, 30),
      windowEnd: windowEnd ?? const ClockTime(20, 30),
    );

SnipeRule ruleFor(HuntConfig config) =>
    config.toRule(id: 'r1', account: 'a1');

/// A client that records when each basket read started and finished.
class TimelineClient implements PortalClient {
  TimelineClient({this.pages = const [], this.claimBehavior = ClaimBehavior.succeed});

  /// Successive basket pages; the last repeats once exhausted.
  final List<List<Listing>> pages;
  final ClaimBehavior claimBehavior;

  /// The moment each poll started, on the injected timeline.
  final List<int> pollStarts = [];

  /// The moment each poll finished.
  final List<int> pollEnds = [];

  /// The waits the engine asked for.
  final List<Duration> sleeps = [];

  /// The date filter each poll was given, null for the page's default.
  final List<String?> cursors = [];

  /// The length of each simulated response.
  Duration responseDuration = Duration.zero;

  int claimCalls = 0;
  int clock = 0;

  void advance(Duration d) => clock += d.inMilliseconds;

  @override
  Future<BasketPage> fetchBasket(Session session, {String? cursor}) async {
    pollStarts.add(clock);
    cursors.add(cursor);

    final index = pages.isEmpty
        ? -1
        : (pollStarts.length <= pages.length
            ? pollStarts.length - 1
            : pages.length - 1);

    await Future<void>.delayed(Duration.zero);
    advance(responseDuration);
    pollEnds.add(clock);

    if (index < 0) return const BasketPage(listings: []);
    return BasketPage(listings: pages[index]);
  }

  @override
  Future<ClaimResult> claim(Session session, ListingId listingId) async {
    claimCalls++;
    switch (claimBehavior) {
      case ClaimBehavior.succeed:
        return ClaimSucceeded(Reservation(
          id: 'r-$listingId',
          date: DateTime.utc(2026, 10, 28),
          slot: MealSlot.dinner,
          hall: central,
          option: const MenuOption(id: 'o1', name: 'لوبیا پلو', priceRial: 350000),
          state: ReservationState.active,
        ));
      case ClaimBehavior.reject:
        return const ClaimRejected('taken');
      case ClaimBehavior.ambiguous:
        return const ClaimAmbiguous('timeout');
      case ClaimBehavior.throw_:
        throw Exception('reset');
    }
  }

  @override
  Future<Balance> fetchBalance(Session session) async =>
      Balance(amountRial: 5000000, fetchedAt: DateTime.utc(2026, 10, 18));

  @override
  Future<List<Reservation>> fetchReservations(Session session) async => const [];

  @override
  Future<BasketHoldStatus?> holdingsOnBuyPage(
    Session session, {
    required DateTime date,
    required String optionId,
  }) async =>
      null;

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
        establishedAt: DateTime.utc(2026, 10, 18),
      );

  @override
  Future<Session> refresh(Session session) async => session;

  @override
  Future<void> logout(Session session) async {}

  @override
  Future<DateTime> fetchServerTime(Session session) async =>
      DateTime.utc(2026, 10, 18, 7, 0);

  @override
  Future<List<MealOffering>> fetchOfferings(Session s, DateTime date) async =>
      const [];

  @override
  Future<Reservation> reserve(Session session, MealOffering offering) async =>
      throw UnimplementedError();

  @override
  Future<List<Transaction>> fetchTransactions(Session session) async =>
      const [];

  @override
  Future<void> cancel(Session session, MealId mealId) async {}

  @override
  Uri? topUpUrl(Session session) => null;
}

enum ClaimBehavior { succeed, reject, ambiguous, throw_ }

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

/// Records what the engine reported.
class RecordingListener implements HuntOutcomeListener {
  final List<String> claims = [];
  final List<String> ends = [];

  @override
  Future<void> onClaimed({
    required String ruleId,
    required Listing listing,
    required Reservation reservation,
  }) async {
    claims.add('${reservation.option.name}@${listing.hall.name}');
  }

  @override
  Future<void> onEnded({
    required String ruleId,
    required SnipeState state,
    required String reason,
  }) async {
    ends.add('$state:$reason');
  }
}

/// Builds an engine on a controllable timeline.
class Harness {
  Harness({
    required this.client,
    required this.config,
    required this.listener,
    DateTime? now,
  }) : clock = FixedServerClock.now(now ?? DateTime.utc(2026, 10, 28, 12, 0)) {
    engine = DefaultSnipeEngine(
      client: client,
      sessions: SessionManager(
        client: client,
        store: AlwaysStore(),
        solver: NoopSolver(),
        clock: clock,
      ),
      clock: clock,
      listener: listener,
      random: Random(1),
      sleep: (d) async {
        client.sleeps.add(d);
        client.advance(d);
      },
    );
  }

  final TimelineClient client;
  final HuntConfig config;
  final RecordingListener listener;
  final FixedServerClock clock;
  late final DefaultSnipeEngine engine;
}

void main() {
  group('the timing rule', () {
    test('the next request starts only after the interval, measured from '
        'the end of the previous one', () async {
      // The important test: it is easy to write an engine that respects the
      // interval when responses are instant and violates it when a response
      // is slow. So the response here is deliberately slow.
      final client = TimelineClient(pages: [[]]);
      client.responseDuration = const Duration(milliseconds: 1500);

      final harness = Harness(
        client: client,
        config: huntConfig(
          rate: HuntRate(
            peakInterval: const Duration(seconds: 10),
            offPeakInterval: const Duration(minutes: 15),
          ),
        ),
        listener: RecordingListener(),
        // 18:00 portal-local is inside the dinner distribution window, so the
        // hunt polls at the peak rate.
        now: DateTime.utc(2026, 10, 28, 14, 30),
      );

      await harness.engine.start(ruleFor(harness.config), hunt: harness.config);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await harness.engine.stop('r1');

      expect(client.pollStarts.length, greaterThanOrEqualTo(2));

      // The gap between the end of one response and the start of the next is
      // at least the interval. Anything less would overlap two requests.
      for (var i = 1; i < client.pollStarts.length; i++) {
        final gap = client.pollStarts[i] - client.pollEnds[i - 1];
        expect(
          gap,
          greaterThanOrEqualTo(10000),
          reason: 'request $i started $gap ms after the previous one finished',
        );
      }
    });

    test('the wait is never measured from the start of the request', () async {
      final client = TimelineClient(pages: [[]]);
      client.responseDuration = const Duration(milliseconds: 1500);

      final harness = Harness(
        client: client,
        config: huntConfig(),
        listener: RecordingListener(),
        now: DateTime.utc(2026, 10, 28, 14, 30),
      );

      await harness.engine.start(ruleFor(harness.config), hunt: harness.config);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await harness.engine.stop('r1');

      expect(client.pollStarts.length, greaterThanOrEqualTo(2));

      // The interval is 10s and the response takes 1.5s, so the second
      // request must start at least 11.5s after the first — not at 10s.
      final total = client.pollStarts[1] - client.pollStarts[0];
      expect(total, greaterThanOrEqualTo(11500));
    });
  });

  group('the peak and off-peak rate', () {
    test('inside the distribution window the hunt polls at the peak rate',
        () async {
      final client = TimelineClient(pages: [[]]);
      final harness = Harness(
        client: client,
        config: huntConfig(
          rate: HuntRate(
            peakInterval: const Duration(seconds: 10),
            offPeakInterval: const Duration(minutes: 15),
          ),
        ),
        listener: RecordingListener(),
        // 18:00 portal-local: inside the 16:30-20:30 dinner window.
        now: DateTime.utc(2026, 10, 28, 14, 30),
      );

      await harness.engine.start(ruleFor(harness.config), hunt: harness.config);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await harness.engine.stop('r1');

      expect(client.sleeps, isNotEmpty);
      // The jitter only ever lengthens the wait: the interval is a floor the
      // user set, so the wait is between 10s and 12s.
      expect(client.sleeps.first.inMilliseconds, inInclusiveRange(10000, 12000));
    });

    test('outside it, the hunt polls at the off-peak rate', () async {
      final client = TimelineClient(pages: [[]]);
      final harness = Harness(
        client: client,
        config: huntConfig(
          // A window wide enough to contain the off-peak hour under test.
          windowStart: const ClockTime(9, 0),
          windowEnd: const ClockTime(23, 0),
          rate: HuntRate(
            peakInterval: const Duration(seconds: 10),
            offPeakInterval: const Duration(minutes: 15),
          ),
        ),
        listener: RecordingListener(),
        // 12:00 portal-local: outside the dinner distribution window.
        now: DateTime.utc(2026, 10, 28, 8, 30),
      );

      await harness.engine.start(ruleFor(harness.config), hunt: harness.config);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await harness.engine.stop('r1');

      expect(client.sleeps, isNotEmpty);
      final wait = client.sleeps.first.inMilliseconds;
      expect(wait, inInclusiveRange(12 * 60 * 1000, 18 * 60 * 1000));
    });

    test('a lunch hunt peaks in the morning, not in the evening', () async {
      final client = TimelineClient(pages: [[]]);
      final harness = Harness(
        client: client,
        config: huntConfig(
          slot: MealSlot.lunch,
          // A window covering the morning, and not the dinner peak.
          windowStart: const ClockTime(9, 0),
          windowEnd: const ClockTime(15, 30),
          rate: HuntRate(
            peakInterval: const Duration(seconds: 10),
            offPeakInterval: const Duration(minutes: 15),
          ),
        ),
        listener: RecordingListener(),
        // 12:00 portal-local: inside the 09:00-15:30 lunch window.
        now: DateTime.utc(2026, 10, 28, 8, 30),
      );

      await harness.engine.start(ruleFor(harness.config), hunt: harness.config);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await harness.engine.stop('r1');

      expect(client.sleeps.first.inMilliseconds, inInclusiveRange(10000, 12000));
    });

    test('a lunch hunt is off-peak in the evening', () async {
      final client = TimelineClient(pages: [[]]);
      final harness = Harness(
        client: client,
        config: huntConfig(
          slot: MealSlot.lunch,
          windowStart: const ClockTime(9, 0),
          windowEnd: const ClockTime(20, 0),
          rate: HuntRate(
            peakInterval: const Duration(seconds: 10),
            offPeakInterval: const Duration(minutes: 15),
          ),
        ),
        listener: RecordingListener(),
        // 18:00 portal-local: outside the lunch distribution window, so a
        // lunch hunt must be quiet even though a dinner hunt would be hot.
        now: DateTime.utc(2026, 10, 28, 14, 30),
      );

      await harness.engine.start(ruleFor(harness.config), hunt: harness.config);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await harness.engine.stop('r1');

      expect(client.sleeps, isNotEmpty);
      expect(client.sleeps.first.inMilliseconds,
          inInclusiveRange(12 * 60 * 1000, 18 * 60 * 1000));
    });
  });

  group('terminate on success', () {
    test('a successful purchase stops the hunt, and it never polls again',
        () async {
      final client = TimelineClient(pages: [
        [marketListing(optionId: '99999', name: 'لوبیا پلو')],
      ]);
      final listener = RecordingListener();
      final harness = Harness(
        client: client,
        config: huntConfig(),
        listener: listener,
        now: DateTime.utc(2026, 10, 28, 14, 30),
      );

      await harness.engine.start(ruleFor(harness.config), hunt: harness.config);
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(client.claimCalls, 1);
      expect(
        client.pollStarts.length,
        1,
        reason: 'a second poll could buy a second, unwanted meal',
      );
      expect(listener.claims, hasLength(1));
      expect(listener.claims.single, contains('لوبیا پلو'));
    });

    test('a dry run also stops the hunt', () async {
      final client = TimelineClient(pages: [
        [marketListing(optionId: '99999', name: 'لوبیا پلو')],
      ]);
      final harness = Harness(
        client: client,
        config: huntConfig(),
        listener: RecordingListener(),
        now: DateTime.utc(2026, 10, 28, 14, 30),
      );

      final rule = harness.config.toRule(id: 'r1', account: 'a1', dryRun: true);
      await harness.engine.start(rule, hunt: harness.config);
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(client.claimCalls, 0, reason: 'a dry run never calls the write path');
      expect(client.pollStarts.length, 1);

      final ledger = harness.engine.ledgerFor('r1')!;
      expect(ledger.simulatedPurchaseCount, 1);
      expect(ledger.purchaseCount, 0);
    });

    test('a rejected claim does not stop the hunt', () async {
      final client = TimelineClient(
        pages: [
          [marketListing(optionId: '99999', name: 'لوبیا پلو')],
        ],
        claimBehavior: ClaimBehavior.reject,
      );
      final harness = Harness(
        client: client,
        config: huntConfig(),
        listener: RecordingListener(),
        now: DateTime.utc(2026, 10, 28, 14, 30),
      );

      await harness.engine.start(ruleFor(harness.config), hunt: harness.config);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await harness.engine.stop('r1');

      expect(client.pollStarts.length, greaterThan(1),
          reason: 'the hunt continues until the window closes');
    });
  });

  group('the hunt polls the target date', () {
    test('the basket is read with the target date as its filter', () async {
      final client = TimelineClient(pages: [[]]);
      final harness = Harness(
        client: client,
        config: huntConfig(),
        listener: RecordingListener(),
        now: DateTime.utc(2026, 10, 28, 14, 30),
      );

      await harness.engine.start(ruleFor(harness.config), hunt: harness.config);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await harness.engine.stop('r1');

      expect(client.cursors, isNotEmpty);
      expect(client.cursors.first, '1405/08/06');
    });
  });

  group('the pre-flight refusals', () {
    test('a hunt for a slot the account already holds never starts',
        () async {
      final client = TimelineClient(pages: [[]]);
      final config = huntConfig();
      final harness = Harness(
        client: client,
        config: config,
        listener: RecordingListener(),
        now: DateTime.utc(2026, 10, 28, 14, 30),
      );

      // The account already holds this meal.
      final listener = RecordingListener();
      final engine = DefaultSnipeEngine(
        client: _HoldingClient(),
        sessions: SessionManager(
          client: _HoldingClient(),
          store: AlwaysStore(),
          solver: NoopSolver(),
          clock: harness.clock,
        ),
        clock: harness.clock,
        listener: listener,
        random: Random(1),
        sleep: (_) async {},
      );

      await engine.start(ruleFor(config), hunt: config);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      final ledger = engine.ledgerFor('r1')!;
      expect(
        ledger.entries.any((e) => e.kind == LedgerEventKind.preflightFailed),
        isTrue,
      );
      expect(listener.claims, isEmpty);
    });
  });
}

/// A client whose account already holds a dinner on the target date.
class _HoldingClient extends TimelineClient {
  @override
  Future<List<Reservation>> fetchReservations(Session session) async => [
        Reservation(
          id: 'r1',
          date: DateTime.utc(2026, 10, 28),
          slot: MealSlot.dinner,
          hall: central,
          option: const MenuOption(id: 'o1', name: 'x', priceRial: 350000),
          state: ReservationState.active,
        ),
      ];
}
