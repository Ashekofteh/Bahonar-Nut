/// Session management: keeping N accounts authenticated with no user effort.
///
/// The portal binds its CAPTCHA answer to the session at image-fetch time, so a
/// login is an atomic sequence (fetch page, fetch challenge, answer, post) that
/// must not be interleaved with other requests. That constraint is why
/// [SessionManager] serialises authentication per account rather than firing
/// logins concurrently.
///
/// The design intent: the common case is that a stored session still works, and
/// the user never notices anything. Re-authentication is the exception, and when
/// it happens it should be invisible — the CAPTCHA solver reads the code in
/// milliseconds without involving anyone.
library;

import 'models.dart';
import 'portal.dart';

/// Credentials for one account.
///
/// Held only in memory for the duration of a login, and at rest inside the
/// platform keystore. Never logged, never serialised to plain storage.
class Credentials {
  const Credentials({required this.studentId, required this.password});

  final String studentId;
  final String password;

  /// Deliberately omits the password so an accidental log or `print` leaks
  /// nothing. Do not "improve" this to include it.
  @override
  String toString() => 'Credentials(studentId: $studentId, password: <redacted>)';
}

/// A stored account plus its session, as persisted between runs.
class StoredSession {
  const StoredSession({
    required this.accountId,
    required this.cookies,
    required this.establishedAt,
  });

  final AccountId accountId;
  final Map<String, String> cookies;
  final DateTime establishedAt;

  Session toSession() => Session(
        account: accountId,
        cookies: cookies,
        establishedAt: establishedAt,
      );

  static StoredSession fromSession(AccountId accountId, Session session) =>
      StoredSession(
        accountId: accountId,
        cookies: session.cookies,
        establishedAt: session.establishedAt,
      );
}

/// Persistence for credentials and sessions.
///
/// Implementations MUST encrypt at rest (Android Keystore / Windows DPAPI).
/// Nothing in this interface may write plaintext credentials to disk.
abstract class SessionStore {
  Future<Credentials?> readCredentials(AccountId accountId);
  Future<void> writeCredentials(AccountId accountId, Credentials credentials);

  Future<StoredSession?> readSession(AccountId accountId);
  Future<void> writeSession(StoredSession session);
  Future<void> deleteSession(AccountId accountId);

  /// Removes everything for an account, credentials included. Used when the
  /// user deletes an account, which must be complete and irreversible.
  Future<void> purge(AccountId accountId);
}

/// Solves a login challenge. Implemented by the on-device CAPTCHA solver.
///
/// Returns null when it declines to guess — which callers must treat as "ask the
/// user", never as "try anyway".
abstract class ChallengeSolver {
  Future<String?> solve(LoginChallenge challenge);
}

/// Outcome of ensuring an account is authenticated.
sealed class SessionResult {
  const SessionResult();
}

/// The account has a usable session, whether reused or freshly obtained.
class SessionReady extends SessionResult {
  const SessionReady({required this.session, required this.wasReused});

  final Session session;

  /// True when the stored session still worked and no login was needed.
  final bool wasReused;
}

/// The account could not be authenticated, and the user must act.
class SessionUnavailable extends SessionResult {
  const SessionUnavailable({required this.reason, required this.cause});

  final String reason;
  final SessionFailureCause cause;
}

enum SessionFailureCause {
  /// No credentials stored for this account.
  noCredentials,

  /// The portal rejected the username or password.
  badCredentials,

  /// The CAPTCHA solver declined and no human was available to help.
  challengeUnsolvable,

  /// The portal was unreachable or returned an unexpected response.
  networkError,

  /// The portal's clock could not be read, so trustworthiness is unknown.
  clockUnsynced,
}

/// Why a session had to be re-established, for diagnostics.
enum ReauthReason {
  /// No stored session at all.
  firstLogin,

  /// The portal rejected the stored cookies.
  sessionExpired,

  /// A read failed in a way that suggests the session is stale.
  readFailed,

  /// The session was older than the configured maximum age.
  agedOut,
}

/// Result of a lightweight session check.
class SessionCheck {
  const SessionCheck({required this.valid, this.reason});

  final bool valid;
  final String? reason;

  static const ok = SessionCheck(valid: true);
  factory SessionCheck.invalid(String reason) =>
      SessionCheck(valid: false, reason: reason);
}