/// Exercises the typed-CAPTCHA path against the live portal.
///
/// READ-ONLY: it only logs in. It never reserves, buys, cancels or lists.
///
/// ## Why
///
/// The typed-answer path was broken: every correct answer was refused,
/// because the app posted the student's digits against a challenge it had
/// fetched itself, and the portal judges an answer against the **session**
/// the image came from.
///
/// This probe drives the **real** code — [SessionManager] over the real
/// [CullinanPortalClient] — with a solver that always declines, so the app
/// asks for the answer exactly as it does on the device. The answer it then
/// types is read off the image by the real solver, so it is guaranteed
/// correct.
///
/// So a success here means: the app asks, the student reads the image, the
/// answer lands, and the portal accepts it.
///
/// Usage: `dart run tool/_typed_answer_live_probe.dart <studentId> <password>`
// Diagnostic CLI tool: stdout printing is the entire point.
// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings

library;

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/adapter/cullinan_client.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/core/session.dart';
import 'package:bahonar_nut/core/session_manager.dart';
import 'package:bahonar_nut/core/time.dart';
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
    print('usage: dart run tool/_typed_answer_live_probe.dart <id> <pass>');
    return;
  }
  final studentId = args[0];
  final password = args[1];

  final transport = PortalTransport(baseUri: Uri.parse(_base));
  final client = CullinanPortalClient(transport: transport);
  final store = _MemoryStore();
  final manager = SessionManager(
    client: client,
    store: store,
    solver: _DecliningSolver(),
    clock: FixedServerClock.now(DateTime.now().toUtc()),
  );

  const accountId = 'a1';
  await store.writeCredentials(
    accountId,
    Credentials(studentId: studentId, password: password),
  );

  try {
    // --- The app asks, because the solver declined ---
    final asked = await manager.ensureSession(accountId);
    if (asked is! SessionNeedsCaptcha) {
      print('UNEXPECTED: the app did not ask the student. Got: $asked');
      return;
    }
    print('1. the app asked the student for the code');
    print('   image: ${asked.imageBytes.length} bytes');
    print('   session: ${asked.sessionId ?? "(none)"}');

    // --- The student reads it ---
    final answer = CaptchaSolver().solve(asked.imageBytes).text!;
    print('2. the student read the code: $answer');

    // --- And types it in ---
    final result = await manager.loginWithCaptcha(
      accountId,
      answer,
      sessionId: asked.sessionId,
    );
    if (result is SessionReady) {
      print('3. RESULT: LOGIN OK -- the portal accepted the typed answer');
      print('   cookies ${result.session.cookies.keys.toList()}');

      // --- And the session really works ---
      final balance = await client.fetchBalance(result.session);
      print('4. the session reads the portal: ${balance.amountRial} Rial');
    } else {
      print('3. RESULT: REFUSED: $result');
    }
  } catch (e, st) {
    print('EXCEPTION: $e');
    print(st.toString().split('\n').take(8).join('\n'));
  } finally {
    transport.close();
  }
}
