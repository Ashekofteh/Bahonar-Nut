/// Session lifecycle orchestration.
///
/// Responsibilities, in order of how often they actually matter:
///   1. **Reuse.** A stored session usually still works. Do nothing, spend
///      nothing, involve nobody.
///   2. **Re-authenticate.** When it does not, log in again. The CAPTCHA solver
///      reads the challenge locally, so this is invisible to the user.
///   3. **Serialise.** One login per account at a time. The portal binds the
///      challenge to the session at fetch time, so overlapping logins for the
///      same account would corrupt each other.
///
/// This class holds no I/O of its own: the [PortalClient] and [SessionStore] are
/// injected, so the whole lifecycle is testable with fakes and a fake clock.
library;

import 'dart:async';

import 'models.dart';
import 'portal.dart';
import 'session.dart';
import 'time.dart';

/// Configuration for session reuse.
class SessionPolicy {
  const SessionPolicy({
    this.maxAge = const Duration(hours: 12),
    this.stalenessLimit = const Duration(minutes: 15),
  });

  /// How long a stored session is trusted without checking, even if it looks
  /// fine. Bounds the damage of the portal silently invalidating sessions.
  final Duration maxAge;

  /// How old a clock sync may be before it is considered stale.
  final Duration stalenessLimit;
}

/// Manages authenticated sessions for a set of accounts.
class SessionManager {
  SessionManager({
    required this.client,
    required this.store,
    required this.solver,
    required this.clock,
    this.policy = const SessionPolicy(),
  });

  /// Dependencies are injected rather than constructed, so the whole session
  /// lifecycle is testable with fakes and no network.
  final PortalClient client;
  final SessionStore store;
  final ChallengeSolver solver;
  final ServerClock clock;

  final SessionPolicy policy;

  /// In-memory sessions, so a hot account does not re-read the store each call.
  final Map<AccountId, Session> _live = {};

  /// Tail of the per-account operation queue.
  ///
  /// Authentication is serialised per account because the portal binds a CAPTCHA
  /// challenge to the session when the image is fetched: two overlapping logins
  /// for one account would fetch and submit in interleaved order and corrupt each
  /// other. Each call chains onto the previous one for that account.
  final Map<AccountId, Future<void>> _queues = {};

  /// Ensures [accountId] is authenticated, reusing or re-establishing as needed.
  ///
  /// [force] skips the reuse path, for the case where a read failed in a way
  /// that suggests the session is stale despite looking valid.
  ///
  /// Concurrent calls for the same account run one after another; calls for
  /// different accounts proceed independently.
  Future<SessionResult> ensureSession(
    AccountId accountId, {
    bool force = false,
  }) {
    final previous = _queues[accountId];
    final completer = Completer<SessionResult>();

    Future<void> run() async {
      try {
        completer.complete(await _ensure(accountId, force: force));
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    }

    final chained = (previous ?? Future<void>.value()).then((_) => run());

    // Record this as the queue tail, but never let a failure poison the chain:
    // the next caller should still get a chance to run.
    final tail = chained.then((_) {}, onError: (_) {});
    _queues[accountId] = tail;
    tail.whenComplete(() {
      if (identical(_queues[accountId], tail)) _queues.remove(accountId);
    });

    return completer.future;
  }

  Future<SessionResult> _ensure(AccountId accountId, {required bool force}) async {
    // 1. Trust an in-memory session that is not aged out.
    if (!force) {
      final live = _live[accountId];
      if (live != null && !_isAgedOut(live)) {
        return SessionReady(session: live, wasReused: true);
      }

      // 2. Fall back to a stored session.
      final stored = await store.readSession(accountId);
      if (stored != null && !_isAgedOut(stored.toSession())) {
        final session = stored.toSession();
        _live[accountId] = session;
        return SessionReady(session: session, wasReused: true);
      }
    }

    // 3. Re-authenticate.
    final credentials = await store.readCredentials(accountId);
    if (credentials == null) {
      return const SessionUnavailable(
        reason: 'اطلاعات ورود این حساب ذخیره نشده است.',
        cause: SessionFailureCause.noCredentials,
      );
    }

    return _login(accountId, credentials);
  }

  Future<SessionResult> _login(
    AccountId accountId,
    Credentials credentials,
  ) async {
    try {
      final challenge = await client.beginLogin(credentials.studentId);

      LoginChallengeResponse? response;
      if (challenge != null) {
        final answer = await solver.solve(challenge);
        if (answer == null) {
          return const SessionUnavailable(
            reason: 'کد امنیتی به‌صورت خودکار خوانده نشد.',
            cause: SessionFailureCause.challengeUnsolvable,
          );
        }
        response = LoginChallengeResponse(answer);
      }

      final session = await client.completeLogin(
        username: credentials.studentId,
        password: credentials.password,
        challenge: response,
      );

      _live[accountId] = session;
      await store.writeSession(StoredSession.fromSession(accountId, session));
      return SessionReady(session: session, wasReused: false);
    } on LoginRejectedException catch (e) {
      return SessionUnavailable(
        reason: 'نام کاربری یا گذرواژه پذیرفته نشد: ${e.message}',
        cause: SessionFailureCause.badCredentials,
      );
    } on PortalUnreachableException catch (e) {
      return SessionUnavailable(
        reason: 'ارتباط با سامانه برقرار نشد: ${e.message}',
        cause: SessionFailureCause.networkError,
      );
    } catch (e) {
      return SessionUnavailable(
        reason: 'ورود با خطای غیرمنتظره مواجه شد: $e',
        cause: SessionFailureCause.networkError,
      );
    }
  }

  /// Whether the clock is trustworthy enough to act on.
  ///
  /// Callers gate auto-reserve on this. An unsynced clock means the cutoff
  /// boundary is unknown, and guessing would either refuse a legal action or
  /// fire one too early.
  bool get isClockTrustworthy =>
      clock.isSynced && clock.staleness <= policy.stalenessLimit;

  bool _isAgedOut(Session session) =>
      DateTime.now().toUtc().difference(session.establishedAt.toUtc()) >
      policy.maxAge;

  /// Forgets a session in memory and on disk, forcing a fresh login next time.
  Future<void> invalidate(AccountId accountId) async {
    _live.remove(accountId);
    await store.deleteSession(accountId);
  }

  /// Logs out and removes everything for an account.
  Future<void> forget(AccountId accountId) async {
    final session = _live.remove(accountId);
    if (session != null) {
      try {
        await client.logout(session);
      } catch (_) {
        // A failed logout must not block removing local state: the user asked
        // for this account to be gone, and a portal-side hiccup is not their
        // problem.
      }
    }
    await store.purge(accountId);
  }

  /// The cached session for an account, or null when none is live.
  Session? sessionFor(AccountId accountId) => _live[accountId];

  /// Drops all in-memory sessions. Used when the app is backgrounded long
  /// enough that a clock offset may no longer hold.
  void clearMemory() => _live.clear();
}

/// The portal rejected the supplied credentials.
class LoginRejectedException implements Exception {
  const LoginRejectedException(this.message);

  final String message;

  @override
  String toString() => 'LoginRejectedException: $message';
}

/// The portal could not be reached, or returned something unusable.
class PortalUnreachableException implements Exception {
  const PortalUnreachableException(this.message);

  final String message;

  @override
  String toString() => 'PortalUnreachableException: $message';
}