/// The app's **real** sync path, run against the live portal.
///
/// The device's store ended up with six meals while the portal held seven,
/// and the app reported a cancel that never happened. Both point at the same
/// place: the reads.
///
/// This runs the actual [PortalSync] over the actual [LocalMealStore], with
/// the actual client and the actual [SessionManager], and prints what the
/// store ends up holding. It is read-only.
///
/// ## The two sessions
///
/// The app **restores** a session from storage; a probe normally logs in
/// fresh. The restored session is the one the app actually uses, so this can
/// take a session cookie map on the command line and use it instead of
/// logging in — which is the difference under test.
///
/// Usage:
///   dart run tool/sync_live.dart <studentId> <password>
///   dart run tool/sync_live.dart --session '<cookie json>' <studentId>
///
library;

// One-shot live probe tool: stdout printing is the entire point.
// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings

import 'dart:convert';

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/adapter/cullinan_client.dart';
import 'package:bahonar_nut/core/local_meal_store.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/core/session.dart';
import 'package:bahonar_nut/core/session_manager.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:bahonar_nut/platform/portal_sync.dart';
import 'package:bahonar_nut/transport/http_transport.dart';

const _base = 'https://nut.uk.ac.ir/';

/// A session store that hands back a fixed session, so the manager does not
/// log in — which is what the app does when it restores one.
class _FixedStore implements SessionStore {
  _FixedStore(this.stored);

  final StoredSession? stored;

  @override
  Future<Credentials?> readCredentials(AccountId accountId) async => null;

  @override
  Future<void> writeCredentials(AccountId accountId, Credentials credentials) async {}

  @override
  Future<StoredSession?> readSession(AccountId accountId) async => stored;

  @override
  Future<void> writeSession(StoredSession session) async {}

  @override
  Future<void> deleteSession(AccountId accountId) async {}

  @override
  Future<void> purge(AccountId accountId) async {}
}

/// A solver that is never asked: the session is restored, not established.
class _NoopSolver implements ChallengeSolver {
  @override
  Future<String?> solve(LoginChallenge challenge) async => null;
}

Future<void> main(List<String> argv) async {
  var args = argv;
  Map<String, String>? restored;
  if (args.isNotEmpty && args.first == '--session') {
    restored = (jsonDecode(args[1]) as Map<String, dynamic>)
        .map((k, v) => MapEntry(k, v.toString()));
    args = args.sublist(2);
  }
  if (args.length < 2) {
    print('usage: dart run tool/sync_live.dart <studentId> <password>');
    return;
  }
  final user = args[0];
  final pass = args[1];

  final clock = SyncedServerClock();
  final transport = PortalTransport(baseUri: Uri.parse(_base), clock: clock);
  final client = CullinanPortalClient(transport: transport);

  try {
    StoredSession? stored;
    if (restored != null) {
      transport.restoreSession(user, restored);
      stored = StoredSession(
        accountId: user,
        cookies: restored,
        establishedAt: DateTime.now().toUtc(),
      );
      print('using a RESTORED session: ${restored['ASP.NET_SessionId']}');
    } else {
      final page = await transport.get(user, '/');
      final captcha =
          await transport.getBytes(user, '/UserControls/Captcha.ashx');
      final solution = CaptchaSolver().solve(captcha);
      final login = await transport.post(user, '/', body: {
        '__VIEWSTATE': _input(page.body, '__VIEWSTATE'),
        '__VIEWSTATEGENERATOR': _input(page.body, '__VIEWSTATEGENERATOR'),
        '__VIEWSTATEENCRYPTED': '',
        'txtUsername': user,
        'txtPassword': pass,
        'txtCaptcha': solution.text!,
        'btnLogin': 'ورود سمت سرور ',
      });
      if (login.body.contains('txtUsernamePlain')) {
        print('!! LOGIN FAILED');
        return;
      }
      final cookies = transport.jars.jarFor(user).cookies;
      stored = StoredSession(
        accountId: user,
        cookies: cookies,
        establishedAt: DateTime.now().toUtc(),
      );
      print('using a FRESH session: ${cookies['ASP.NET_SessionId']}');
    }

    // The app's own sync, over the app's own store.
    final store = LocalMealStore();
    final sessions = SessionManager(
      client: client,
      store: _FixedStore(stored),
      solver: _NoopSolver(),
      clock: clock,
    );
    final sync = PortalSync(
      client: client,
      sessions: sessions,
      mealStore: store,
    );

    print('\n=== the sync');
    final result = await sync.sync(user);
    print('  ok: ${result.ok}  ${result.error ?? ''}');
    print('  balance: ${result.balanceRial}');
    print('  reservations: ${result.reservations.length}');
    for (final r in result.reservations) {
      print('     ${_d(r.date)} ${r.slot.name}');
    }
    print('  transactions: ${result.transactions.length}');

    print('\n=== the store');
    print('  count: ${store.count}');
    for (final m in store.all) {
      print('     ${_d(m.date)} ${m.slot.name}  ${m.source.name}  '
          '${m.dishName ?? ''}');
    }
  } catch (e, st) {
    print('EXCEPTION: $e');
    print(st.toString().split('\n').take(8).join('\n'));
  } finally {
    transport.close();
  }
}

String _d(DateTime date) => date.toIso8601String().substring(0, 10);

String _input(String html, String id) {
  final m = RegExp('id="' + RegExp.escape(id) + r'"[^>]*value="([^"]*)"')
      .firstMatch(html);
  return m?.group(1) ?? '';
}
