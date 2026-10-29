/// Reproduces the app's **whole** refresh flow, live, with a declining solver.
///
/// READ-ONLY: it only logs in and reads. It never reserves, buys or cancels.
///
/// ## Why
///
/// On the device, the student typed a correct CAPTCHA, the app showed
/// «کد امنیتی به‌صورت خودکار خوانده نشد.», and no second dialog appeared.
///
/// That message comes from two different places — the first sync's error and
/// the second sync's error — and the app shows only one of them. So the
/// device run cannot say which happened:
///
///   * the typed answer was **refused**, or
///   * the typed answer was **accepted** and the read that followed was
///     bounced, so the retry needed a fresh CAPTCHA and the app did not
///     ask again.
///
/// This probe runs the app's own code — [SessionManager] with the real
/// [CullinanPortalClient] and the real [PortalSync] — with a solver that
/// always declines, and prints every step. So the sequence that the device
/// ran is visible, and the step that fails is named.
///
/// Usage: `dart run tool/_typed_sync_live_probe.dart <studentId> <password>`
// Diagnostic CLI tool: stdout printing is the entire point.
// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings

library;

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/adapter/cullinan_client.dart';
import 'package:bahonar_nut/core/local_meal_store.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/core/session.dart';
import 'package:bahonar_nut/core/session_manager.dart';
import 'package:bahonar_nut/core/serialised_portal_client.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:bahonar_nut/platform/portal_sync.dart';
import 'package:bahonar_nut/transport/http_transport.dart';

const _base = 'https://nut.uk.ac.ir/';

/// A solver that never answers, so the student is asked.
class _DecliningSolver implements ChallengeSolver {
  @override
  Future<String?> solve(LoginChallenge challenge) async => null;
}

/// An in-memory session store.
class _MemoryStore implements SessionStore {
  final Map<AccountId, Credentials> _credentials = {};
  final Map<AccountId, StoredSession> _sessions = {};

  @override
  Future<Credentials?> readCredentials(AccountId accountId) async =>
      _credentials[accountId];

  @override
  Future<void> writeCredentials(
      AccountId accountId, Credentials credentials) async {
    _credentials[accountId] = credentials;
  }

  @override
  Future<StoredSession?> readSession(AccountId accountId) async =>
      _sessions[accountId];

  @override
  Future<void> writeSession(StoredSession session) async {
    _sessions[session.accountId] = session;
  }

  @override
  Future<void> deleteSession(AccountId accountId) async {
    _sessions.remove(accountId);
  }

  @override
  Future<void> purge(AccountId accountId) async {
    _credentials.remove(accountId);
    _sessions.remove(accountId);
  }
}

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run tool/_typed_sync_live_probe.dart <id> <pass>');
    return;
  }
  final studentId = args[0];
  final password = args[1];

  final transport = PortalTransport(baseUri: Uri.parse(_base));
  final raw = CullinanPortalClient(transport: transport);
  // The app wraps the client in the serialising one, and so does the
  // probe: a read and a login must not interleave for one account.
  final client = SerialisedPortalClient(raw);
  final store = _MemoryStore();
  final manager = SessionManager(
    client: client,
    store: store,
    solver: _DecliningSolver(),
    clock: FixedServerClock.now(DateTime.now().toUtc()),
  );
  final sync = PortalSync(
    client: client,
    sessions: manager,
    mealStore: LocalMealStore(),
  );

  // The local account id is **not** the student id, exactly as on the device.
  const accountId = 'acc-1700000000000-1';
  await store.writeCredentials(
    accountId,
    Credentials(studentId: studentId, password: password),
  );

  try {
    // --- 1. The first sync, the way the app starts it ---
    print('=== 1. the first sync ===');
    final first = await sync.sync(accountId);
    print('ok: ${first.ok}');
    print('error: ${first.error}');
    final challenge = first.needsCaptcha;
    if (challenge == null) {
      print('UNEXPECTED: no challenge. The solver should have declined.');
      return;
    }
    print('challenge session: ${challenge.sessionId}');

    // --- 2. The student reads it ---
    final answer = CaptchaSolver().solve(challenge.imageBytes).text;
    print('\n=== 2. the student read the code: $answer ===');
    if (answer == null) {
      print('the solver could not read this image either');
      return;
    }

    // --- 3. The typed answer, exactly as the UI posts it ---
    print('\n=== 3. the typed answer ===');
    final login = await manager.loginWithCaptcha(
      accountId,
      answer,
      sessionId: challenge.sessionId,
    );
    print('result: $login');

    // --- 4. The second sync, the way the app continues it ---
    print('\n=== 4. the second sync ===');
    final second = await sync.sync(accountId);
    print('ok: ${second.ok}');
    print('error: ${second.error}');
    print('needsCaptcha: ${second.needsCaptcha != null}');
    if (second.needsCaptcha != null) {
      print('  -> the read was BOUNCED and a new challenge is waiting.');
      print('  -> the app does not ask for this one. This is the device bug.');
    }
  } catch (e, st) {
    print('EXCEPTION: $e');
    print(st.toString().split('\n').take(8).join('\n'));
  } finally {
    transport.close();
  }
}
