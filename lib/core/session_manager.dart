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

    return _login(accountId, credentials);  }

  Future<SessionResult> _login(
    AccountId accountId,
    Credentials credentials, {
    String? typedAnswer,
  }) async {
    try {
      final challenge = await client.beginLogin(credentials.studentId);

      LoginChallengeResponse? response;
      if (challenge != null) {
        // A typed answer comes from the student, and it is used **as is**:
        // the solver is not consulted, because the student has already
        // looked at the image and the solver may well read it differently.
        final answer = typedAnswer ?? await solver.solve(challenge);
        if (answer == null) {
          // The solver declined. The image travels with the failure so the
          // student can read the challenge that is actually live — the
          // bytes that were fetched are the ones the answer is judged
          // against.
          return SessionNeedsCaptcha(
            imageBytes: challenge.imageBytes,
            accountId: accountId,
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
      // The portal refused the login. Whether that was the **password** or
      // the **CAPTCHA** matters, and the portal says which: it answers a
      // wrong code with a distinct label. Reporting a wrong code as a
      // wrong password sends the student to change a password that was
      // never the problem.
      if (_isCaptchaRejection(e.message)) {
        return SessionUnavailable(
          reason: 'کد امنیتی درست تشخیص داده نشد.',
          cause: SessionFailureCause.wrongCaptcha,
        );
      }
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

  /// Whether the portal's refusal was about the **CAPTCHA** rather than the
  /// password.
  ///
  /// The portal says which, in the label it renders on a failed login: a
  /// wrong code reads «کد امنیتی صحیح نمی باشد» and a wrong password reads
  /// «نام کاربری یا گذرواژه اشتباه است». They are different problems with
  /// different fixes, and telling a student to change their password because
  /// the app misread four digits is worse than no message at all.
  ///
  /// The check is on the **code**, and the code is the thing the phrase
  /// «کد امنیتی» names. The message has been seen verbatim from the portal,
  /// so the match is on that phrase rather than on the whole sentence — a
  /// portal that rewords it should still be understood.
  static bool _isCaptchaRejection(String message) =>
      message.contains('کد امنیتی');

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

  /// Logs in with a CAPTCHA the student typed.
  ///
  /// ## Why this is a separate call
  ///
  /// The normal login is invisible: the solver reads the code and the student
  /// never sees a challenge. This call is the **fallback** — the solver
  /// declined, the image was shown, and the student read four digits off it.
  ///
  /// So the answer is used as given. The solver is not consulted, because the
  /// student has looked at the image and the solver may well read it
  /// differently — and the solver's opinion is what got us here.
  ///
  /// ## The queue
  ///
  /// The call joins the account's **login queue**, like every other login.
  /// The portal binds the CAPTCHA answer to the session at image-fetch time,
  /// so a login that interleaved with another would be answering a challenge
  /// the other had already rotated.
  ///
  /// The student may take a while to read the code, and the queue holds for
  /// that long. That is the correct trade: a second login would fetch a new
  /// challenge and make the answer the student is about to type wrong.
  Future<SessionResult> loginWithCaptcha(
    AccountId accountId,
    String answer,
  ) {
    final previous = _queues[accountId];
    final completer = Completer<SessionResult>();

    Future<void> run() async {
      try {
        completer.complete(await _loginWithTypedAnswer(accountId, answer));
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    }

    final chained = (previous ?? Future<void>.value()).then((_) => run());
    final tail = chained.then((_) {}, onError: (_) {});
    _queues[accountId] = tail;
    tail.whenComplete(() {
      if (identical(_queues[accountId], tail)) _queues.remove(accountId);
    });

    return completer.future;
  }

  /// The login body for a typed answer.
  ///
  /// It reads the credentials and posts the answer the student gave. A
  /// refusal comes back as a **fresh challenge** rather than a plain error,
  /// because the portal has rotated the challenge: the old image is dead and
  /// the student needs a new one to answer.
  Future<SessionResult> _loginWithTypedAnswer(
    AccountId accountId,
    String answer,
  ) async {
    final credentials = await store.readCredentials(accountId);
    if (credentials == null) {
      return const SessionUnavailable(
        reason: 'اطلاعات ورود این حساب ذخیره نشده است.',
        cause: SessionFailureCause.noCredentials,
      );
    }

    final result = await _login(accountId, credentials, typedAnswer: answer);

    // A refused code needs a new challenge. The portal has rotated it, so
    // the image the student answered is no longer the live one, and
    // re-showing it would invite the same wrong answer.
    if (result is SessionUnavailable &&
        result.cause == SessionFailureCause.wrongCaptcha) {
      final challenge = await _fetchChallenge(credentials.studentId);
      if (challenge != null) {
        return SessionNeedsCaptcha(
          imageBytes: challenge.imageBytes,
          accountId: accountId,
          previousAttempts: 1,
        );
      }
    }

    return result;
  }

  /// Fetches a fresh CAPTCHA, for a challenge the student must answer.
  ///
  /// A failure here is not fatal: the caller falls back to reporting the
  /// refusal, which is still true.
  Future<LoginChallenge?> _fetchChallenge(String username) async {
    try {
      return await client.beginLogin(username);
    } catch (_) {
      return null;
    }
  }

  /// The cached session for an account, or null when none is live.
  Session? sessionFor(AccountId accountId) => _live[accountId];

  /// Runs [read] with a live session, re-logging in if the portal has expired it.
  ///
  /// The portal answers an expired session by serving its login page — a
  /// perfectly valid response that every parser would read as "the page had no
  /// rows". For the hunt's reads that is the dangerous direction: an account
  /// that already holds the meal would read as holding nothing, and the
  /// one-meal pre-flight would pass on a false negative.
  ///
  /// So a bounced session is not an error the caller has to handle. It is
  /// retried once with a fresh login, and only the second failure is reported.
  ///
  /// Throws [SessionUnavailable] when no session can be established at all.
  ///
  /// When the solver declined and the student must answer the CAPTCHA, the
  /// challenge travels with the exception, so the UI can show the image
  /// rather than reporting a dead end.
  Future<T> withSession<T>(
    AccountId accountId,
    Future<T> Function(Session session) read,
  ) async {
    var result = await ensureSession(accountId);
    if (result is! SessionReady) {
      if (result is SessionNeedsCaptcha) {
        throw SessionUnavailableException(
          const SessionUnavailable(
            reason: 'کد امنیتی به‌صورت خودکار خوانده نشد.',
            cause: SessionFailureCause.challengeUnsolvable,
          ),
          needsCaptcha: result,
        );
      }
      throw SessionUnavailableException(result as SessionUnavailable);
    }

    try {
      return await read(result.session);
    } on LoginRejectedException {
      // The session was rejected. It may be an expired session rather than
      // bad credentials, so a fresh login is worth one attempt.
    }

    await invalidate(accountId);
    result = await ensureSession(accountId, force: true);
    if (result is! SessionReady) {
      throw SessionUnavailableException(result as SessionUnavailable);
    }
    return read(result.session);
  }

  /// The account's live session cookies.
  ///
  /// ## Why the top-up needs them
  ///
  /// The bank's gateway returns to the portal, and the portal credits the
  /// account that **started** the payment. So the WebView that shows the
  /// gateway has to carry the portal's session cookies, or the return would
  /// credit nobody (F55).
  ///
  /// The session is **established** if it is not already live, because a
  /// top-up that is started with a stale session would fail at the last
  /// step, in the bank, where the student is least able to tell what went
  /// wrong.
  Future<Map<String, String>> cookiesFor(AccountId accountId) async {
    final result = await ensureSession(accountId);
    if (result is! SessionReady) {
      throw SessionUnavailableException(result as SessionUnavailable);
    }
    return result.session.cookies;
  }

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

/// No session could be established for the account.
///
/// Thrown by [SessionManager.withSession], so a caller that only wants to make
/// a read does not have to branch on [SessionResult] itself.
class SessionUnavailableException implements Exception {
  const SessionUnavailableException(this.unavailable, {this.needsCaptcha});

  final SessionUnavailable unavailable;

  /// The CAPTCHA the student must answer, when the solver declined.
  ///
  /// Carried alongside the failure rather than as a separate exception type,
  /// because it is the **same** failure with something the student can do
  /// about it. A caller that gets this has a path forward; a caller that
  /// gets a plain refusal does not.
  final SessionNeedsCaptcha? needsCaptcha;

  /// The reason, in the user's language.
  String get reason => unavailable.reason;

  @override
  String toString() => 'SessionUnavailableException: ${unavailable.reason}';
}

/// The portal could not be reached, or returned something unusable.
class PortalUnreachableException implements Exception {
  const PortalUnreachableException(this.message);

  final String message;
  @override
  String toString() => 'PortalUnreachableException: $message';
}

/// The portal refused a top-up.
///
/// A distinct type because the portal's own refusal is **silent**: an
/// out-of-range amount re-renders the amount form with no message at all
/// (F56), and an unconfigured bank answers with a server error. Neither is
/// a transport failure, and neither should be retried — the student has to
/// change the amount or the bank.
class TopUpRejectedException implements Exception {
  const TopUpRejectedException(this.message);

  final String message;

  @override
  String toString() => 'TopUpRejectedException: $message';
}

/// The reservation was refused because the date is no longer bookable.
///
/// The portal **refuses a locked date silently**: the row renders `disabled`
/// and the posted reservation is ignored with no error message and no state
/// change. Verified live 2026-10-19. A distinct type is required because the
/// response looks identical to a successful-but-not-yet-rendered post, and
/// treating it as a transport error would make the engine retry a date that
/// can never be booked.
class ReservationLockedException implements Exception {
  const ReservationLockedException(
    this.message, {
    required this.date,
    required this.slot,
  });

  final String message;
  final DateTime date;
  final MealSlot slot;

  @override
  String toString() =>
      'ReservationLockedException: $message (${date.toIso8601String()}, ${slot.name})';
}