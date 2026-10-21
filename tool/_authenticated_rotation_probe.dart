/// Probes whether the session id rotates on **authenticated** reads.
///
/// READ-ONLY: it logs in and reads the reservation page and the balance.
///
/// ## Why
///
/// F77 established that every page GET mints a new `ASP.NET_SessionId`, and
/// that a CAPTCHA answer is bound to the session that was current when the
/// image was fetched.
///
/// The probe above only looked at the *login* page. If authenticated reads
/// rotate the id as well, then the app's stored session goes stale after
/// every read — which would be a much larger problem than the CAPTCHA bug,
/// and would change what the fix has to preserve.
///
/// Usage: `dart run tool/_authenticated_rotation_probe.dart <studentId> <password>`
// Diagnostic CLI tool: stdout printing is the entire point.
// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings

library;

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/adapter/cullinan_client.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/core/session_manager.dart' show LoginRejectedException;
import 'package:bahonar_nut/transport/http_transport.dart';

const _base = 'https://nut.uk.ac.ir/';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run tool/_authenticated_rotation_probe.dart <id> <pw>');
    return;
  }
  final user = args[0];
  final pass = args[1];

  final transport = PortalTransport(baseUri: Uri.parse(_base));
  final client = CullinanPortalClient(transport: transport);

  try {
    // --- Log in ---
    final challenge = await client.beginLogin(user);
    final answer = CaptchaSolver().solve(challenge!.imageBytes).text!;
    await client.completeLogin(
      username: user,
      password: pass,
      challenge: LoginChallengeResponse(answer),
    );
    final jar = transport.jars.jarFor(user);
    print('after login:');
    _dump(jar.cookies);

    // --- Authenticated reads ---
    final session = Session(
      account: user,
      cookies: jar.cookies,
      establishedAt: DateTime.now().toUtc(),
    );

    print('\nafter an authenticated reservation read:');
    await client.fetchReservations(session);
    _dump(jar.cookies);

    print('\nafter an authenticated balance read:');
    await client.fetchBalance(session);
    _dump(jar.cookies);

    print('\nafter a second reservation read:');
    await client.fetchReservations(session);
    _dump(jar.cookies);

    print('\nafter an authenticated reservation read via the raw transport:');
    await transport.get(user, '/Reservation/Reservation.aspx');
    _dump(jar.cookies);
  } on LoginRejectedException catch (e) {
    print('REFUSED: ${e.message}');
  } catch (e) {
    print('ERROR: $e');
  } finally {
    transport.close();
  }
}

void _dump(Map<String, String> cookies) {
  for (final name in ['ASP.NET_SessionId', 'keyId', '__AntiXsrfToken']) {
    final value = cookies[name];
    if (value != null) {
      print('  $name = $value');
    }
  }
}
