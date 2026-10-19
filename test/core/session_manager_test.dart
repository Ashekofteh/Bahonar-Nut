import 'dart:async';
import 'dart:typed_data';

import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/core/session.dart';
import 'package:bahonar_nut/core/session_manager.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:test/test.dart';

/// An in-memory [SessionStore] standing in for the platform keystore.
class FakeSessionStore implements SessionStore {
  final Map<AccountId, Credentials> credentials = {};
  final Map<AccountId, StoredSession> sessions = {};
  int purgeCount = 0;

  @override
  Future<Credentials?> readCredentials(AccountId accountId) async =>
      credentials[accountId];

  @override
  Future<void> writeCredentials(
      AccountId accountId, Credentials creds) async {
    credentials[accountId] = creds;
  }

  @override
  Future<StoredSession?> readSession(AccountId accountId) async =>
      sessions[accountId];

  @override
  Future<void> writeSession(StoredSession session) async {
    sessions[session.accountId] = session;
  }

  @override
  Future<void> deleteSession(AccountId accountId) async {
    sessions.remove(accountId);
  }

  @override
  Future<void> purge(AccountId accountId) async {
    purgeCount++;
    credentials.remove(accountId);
    sessions.remove(accountId);
  }
}

/// A solver that always returns a fixed code, and can be made to decline.
class FakeSolver implements ChallengeSolver {
  FakeSolver({this.answer = '1234', this.declines = false});

  String answer;
  bool declines;
  int solveCount = 0;

  @override
  Future<String?> solve(LoginChallenge challenge) async {
    solveCount++;
    return declines ? null : answer;
  }
}

/// A [PortalClient] that records calls and can be scripted to fail.
class FakePortalClient implements PortalClient {
  int beginLoginCount = 0;
  int completeLoginCount = 0;
  int logoutCount = 0;

  /// When true, [completeLogin] throws [LoginRejectedException].
  bool rejectCredentials = false;

  /// When true, [beginLogin] throws [PortalUnreachableException].
  bool unreachable = false;

  /// When true, [beginLogin] returns a challenge.
  bool issueChallenge = true;

  /// Delay applied to [completeLogin], for concurrency tests.
  Duration loginDelay = Duration.zero;

  @override
  Future<LoginChallenge?> beginLogin(String username) async {
    beginLoginCount++;
    if (unreachable) {
      throw const PortalUnreachableException('connection refused');
    }
    return issueChallenge
        ? LoginChallenge(
            imageBytes: Uint8List.fromList([1, 2, 3]), kind: ChallengeKind.digits4)
        : null;
  }

  @override
  Future<Session> completeLogin({
    required String username,
    required String password,
    LoginChallengeResponse? challenge,
  }) async {
    completeLoginCount++;
    if (loginDelay > Duration.zero) await Future<void>.delayed(loginDelay);
    if (rejectCredentials) {
      throw const LoginRejectedException('کد امنیتی صحیح نمی‌باشد');
    }
    return Session(
      account: username,
      cookies: {'ASP.NET_SessionId': 'sid-$username'},
      establishedAt: DateTime.now().toUtc(),
    );
  }

  @override
  Future<Session> refresh(Session session) async => session;

  @override
  Future<void> logout(Session session) async {
    logoutCount++;
  }

  @override
  Future<DateTime> fetchServerTime(Session session) async =>
      DateTime.utc(2026, 10, 18, 18, 0);

  @override
  Future<Balance> fetchBalance(Session session) async =>
      Balance(amountRial: 225000, fetchedAt: DateTime.utc(2026, 10, 18));

  @override
  Future<List<MealOffering>> fetchOfferings(
          Session session, DateTime date) async =>
      const [];

  @override
  Future<List<Reservation>> fetchReservations(Session session) async => const [];

  @override
  Future<BasketPage> fetchBasket(Session session, {String? cursor}) async =>
      const BasketPage(listings: []);

  @override
  Future<ClaimResult> claim(Session session, ListingId listingId) async =>
      const ClaimRejected('not exercised');

  @override
  Future<Reservation> reserve(Session session, MealOffering offering) =>
      throw UnimplementedError('not exercised');

  @override
  Future<void> cancel(Session session, MealId mealId) async {}

  @override
  Uri? topUpUrl(Session session) => null;
}

SessionManager buildManager({
  required FakePortalClient client,
  required FakeSessionStore store,
  required FakeSolver solver,
  SessionPolicy policy = const SessionPolicy(),
}) =>
    SessionManager(
      client: client,
      store: store,
      solver: solver,
      clock: FixedServerClock.now(DateTime.utc(2026, 10, 18, 18, 0)),
      policy: policy,
    );

void main() {
  late FakePortalClient client;
  late FakeSessionStore store;
  late FakeSolver solver;

  setUp(() {
    client = FakePortalClient();
    store = FakeSessionStore();
    solver = FakeSolver();
  });

  group('first login', () {
    test('logs in when no session is stored', () async {
      await store.writeCredentials(
          'a1', const Credentials(studentId: '401405035', password: 'pw'));

      final manager = buildManager(client: client, store: store, solver: solver);
      final result = await manager.ensureSession('a1');

      expect(result, isA<SessionReady>());
      final ready = result as SessionReady;
      expect(ready.wasReused, isFalse);
      expect(client.completeLoginCount, 1);
      expect(ready.session.cookies['ASP.NET_SessionId'], 'sid-401405035');
    });

    test('solves the challenge and passes the answer through', () async {
      await store.writeCredentials(
          'a1', const Credentials(studentId: '401405035', password: 'pw'));

      final manager = buildManager(client: client, store: store, solver: solver);
      await manager.ensureSession('a1');

      expect(solver.solveCount, 1);
    });

    test('persists the new session', () async {
      await store.writeCredentials(
          'a1', const Credentials(studentId: '401405035', password: 'pw'));

      final manager = buildManager(client: client, store: store, solver: solver);
      await manager.ensureSession('a1');

      expect(store.sessions.containsKey('a1'), isTrue);
    });

    test('logs in even when the portal issues no challenge', () async {
      client.issueChallenge = false;
      await store.writeCredentials(
          'a1', const Credentials(studentId: '401405035', password: 'pw'));

      final manager = buildManager(client: client, store: store, solver: solver);
      final result = await manager.ensureSession('a1');

      expect(result, isA<SessionReady>());
      expect(solver.solveCount, 0, reason: 'nothing to solve');
    });
  });

  group('session reuse', () {
    test('reuses a stored session without logging in', () async {
      store.sessions['a1'] = StoredSession(
        accountId: 'a1',
        cookies: const {'ASP.NET_SessionId': 'stored'},
        establishedAt: DateTime.now().toUtc(),
      );

      final manager = buildManager(client: client, store: store, solver: solver);
      final result = await manager.ensureSession('a1');

      expect(result, isA<SessionReady>());
      expect((result as SessionReady).wasReused, isTrue);
      expect(client.completeLoginCount, 0, reason: 'no login should happen');
      expect((result).session.cookies['ASP.NET_SessionId'], 'stored');
    });

    test('a second call reuses the in-memory session', () async {
      await store.writeCredentials(
          'a1', const Credentials(studentId: 'x', password: 'pw'));

      final manager = buildManager(client: client, store: store, solver: solver);
      await manager.ensureSession('a1');
      await manager.ensureSession('a1');

      expect(client.completeLoginCount, 1, reason: 'only one login');
    });

    test('force bypasses reuse and logs in again', () async {
      store.sessions['a1'] = StoredSession(
        accountId: 'a1',
        cookies: const {'ASP.NET_SessionId': 'stored'},
        establishedAt: DateTime.now().toUtc(),
      );
      await store.writeCredentials(
          'a1', const Credentials(studentId: 'x', password: 'pw'));

      final manager = buildManager(client: client, store: store, solver: solver);
      final result = await manager.ensureSession('a1', force: true);

      expect((result as SessionReady).wasReused, isFalse);
      expect(client.completeLoginCount, 1);
    });

    test('an aged-out session is not reused', () async {
      store.sessions['a1'] = StoredSession(
        accountId: 'a1',
        cookies: const {'ASP.NET_SessionId': 'old'},
        // Older than the default 12h policy.
        establishedAt: DateTime.now().toUtc().subtract(const Duration(days: 2)),
      );
      await store.writeCredentials(
          'a1', const Credentials(studentId: 'x', password: 'pw'));

      final manager = buildManager(client: client, store: store, solver: solver);
      final result = await manager.ensureSession('a1');

      expect((result as SessionReady).wasReused, isFalse);
      expect(client.completeLoginCount, 1);
    });
  });

  group('failure modes are explicit', () {
    test('no stored credentials -> noCredentials', () async {
      final manager = buildManager(client: client, store: store, solver: solver);
      final result = await manager.ensureSession('missing');

      expect(result, isA<SessionUnavailable>());
      expect((result as SessionUnavailable).cause,
          SessionFailureCause.noCredentials);
      expect(client.completeLoginCount, 0);
    });

    test('rejected password -> badCredentials', () async {
      client.rejectCredentials = true;
      await store.writeCredentials(
          'a1', const Credentials(studentId: 'x', password: 'wrong'));

      final manager = buildManager(client: client, store: store, solver: solver);
      final result = await manager.ensureSession('a1');

      expect((result as SessionUnavailable).cause,
          SessionFailureCause.badCredentials);
    });

    test('solver declining -> challengeUnsolvable', () async {
      solver.declines = true;
      await store.writeCredentials(
          'a1', const Credentials(studentId: 'x', password: 'pw'));

      final manager = buildManager(client: client, store: store, solver: solver);
      final result = await manager.ensureSession('a1');

      expect((result as SessionUnavailable).cause,
          SessionFailureCause.challengeUnsolvable);
      expect(client.completeLoginCount, 0,
          reason: 'must not submit without an answer');
    });

    test('unreachable portal -> networkError', () async {
      client.unreachable = true;
      await store.writeCredentials(
          'a1', const Credentials(studentId: 'x', password: 'pw'));

      final manager = buildManager(client: client, store: store, solver: solver);
      final result = await manager.ensureSession('a1');

      expect((result as SessionUnavailable).cause,
          SessionFailureCause.networkError);
    });

    test('a failure never leaves a stale session cached', () async {
      client.rejectCredentials = true;
      await store.writeCredentials(
          'a1', const Credentials(studentId: 'x', password: 'bad'));

      final manager = buildManager(client: client, store: store, solver: solver);
      await manager.ensureSession('a1');

      expect(manager.sessionFor('a1'), isNull);
    });
  });

  group('concurrency: logins are serialised per account', () {
    test('two concurrent calls produce exactly one login', () async {
      client.loginDelay = const Duration(milliseconds: 50);
      await store.writeCredentials(
          'a1', const Credentials(studentId: 'x', password: 'pw'));

      final manager = buildManager(client: client, store: store, solver: solver);

      final results = await Future.wait([
        manager.ensureSession('a1'),
        manager.ensureSession('a1'),
      ]);

      expect(results.every((r) => r is SessionReady), isTrue);
      // The first call logs in and caches; the second, queued behind it, finds
      // the fresh session and reuses it.
      expect(client.completeLoginCount, 1,
          reason: 'serialised calls must not both log in');
    });

    test('different accounts authenticate independently', () async {
      await store.writeCredentials(
          'a1', const Credentials(studentId: 'one', password: 'pw'));
      await store.writeCredentials(
          'a2', const Credentials(studentId: 'two', password: 'pw'));

      final manager = buildManager(client: client, store: store, solver: solver);
      await Future.wait([
        manager.ensureSession('a1'),
        manager.ensureSession('a2'),
      ]);

      expect(client.completeLoginCount, 2);
      expect(manager.sessionFor('a1')!.cookies['ASP.NET_SessionId'], 'sid-one');
      expect(manager.sessionFor('a2')!.cookies['ASP.NET_SessionId'], 'sid-two');
    });

    test('a failing call does not block the next one', () async {
      client.rejectCredentials = true;
      await store.writeCredentials(
          'a1', const Credentials(studentId: 'x', password: 'bad'));

      final manager = buildManager(client: client, store: store, solver: solver);
      final first = await manager.ensureSession('a1');
      expect(first, isA<SessionUnavailable>());

      // Fix the credentials; the next attempt must actually run.
      client.rejectCredentials = false;
      final second = await manager.ensureSession('a1');
      expect(second, isA<SessionReady>());
      expect(client.completeLoginCount, 2);
    });
  });

  group('invalidate and forget', () {
    test('invalidate clears memory and storage so the next call logs in', () async {
      await store.writeCredentials(
          'a1', const Credentials(studentId: 'x', password: 'pw'));

      final manager = buildManager(client: client, store: store, solver: solver);
      await manager.ensureSession('a1');
      await manager.invalidate('a1');

      expect(manager.sessionFor('a1'), isNull);
      expect(store.sessions.containsKey('a1'), isFalse);

      await manager.ensureSession('a1');
      expect(client.completeLoginCount, 2);
    });

    test('forget logs out and purges credentials', () async {
      await store.writeCredentials(
          'a1', const Credentials(studentId: 'x', password: 'pw'));

      final manager = buildManager(client: client, store: store, solver: solver);
      await manager.ensureSession('a1');
      await manager.forget('a1');

      expect(client.logoutCount, 1);
      expect(store.purgeCount, 1);
      expect(store.credentials.containsKey('a1'), isFalse);
      expect(store.sessions.containsKey('a1'), isFalse);
      expect(manager.sessionFor('a1'), isNull);
    });

    test('forget succeeds even when the portal logout fails', () async {
      final throwing = _ThrowingLogoutClient();
      final manager = SessionManager(
        client: throwing,
        store: store,
        solver: solver,
        clock: FixedServerClock.now(DateTime.utc(2026, 10, 18)),
      );
      await store.writeCredentials(
          'a1', const Credentials(studentId: 'x', password: 'pw'));
      await store.writeSession(StoredSession(
        accountId: 'a1',
        cookies: const {'a': 'b'},
        establishedAt: DateTime.now().toUtc(),
      ));

      // Should not throw: the user asked for the account to be gone.
      await manager.forget('a1');
      expect(store.purgeCount, 1);
    });
  });

  group('clock trustworthiness', () {
    test('a synced clock within the staleness limit is trustworthy', () {
      final manager = buildManager(client: client, store: store, solver: solver);
      expect(manager.isClockTrustworthy, isTrue);
    });

    test('an unsynced clock is not trustworthy', () {
      final manager = SessionManager(
        client: client,
        store: store,
        solver: solver,
        clock: _UnsyncedClock(),
      );
      expect(manager.isClockTrustworthy, isFalse);
    });
  });

  group('Credentials redaction', () {
    test('toString never exposes the password', () {
      const creds = Credentials(studentId: '401405035', password: 'sekrit');
      expect(creds.toString(), isNot(contains('sekrit')));
      expect(creds.toString(), contains('401405035'));
    });
  });
}

class _ThrowingLogoutClient extends FakePortalClient {
  @override
  Future<void> logout(Session session) async {
    throw const PortalUnreachableException('timeout');
  }
}

class _UnsyncedClock implements ServerClock {
  @override
  DateTime get nowUtc => DateTime.utc(2026, 10, 18);

  @override
  bool get isSynced => false;

  @override
  Duration get staleness => Duration.zero;
}