/// Measures how long a CAPTCHA challenge stays answerable.
///
/// READ-ONLY: it only logs in.
///
/// ## Why
///
/// F77 established that the answer is bound to the `ASP.NET_SessionId` that
/// was current when the image was fetched, and that restoring that id makes
/// the answer valid again.
///
/// The question this answers decides the shape of the fix: the student has to
/// read four digits off a phone screen, and if the challenge dies after a
/// minute the feature is unusable. So the challenge's lifetime is measured
/// rather than assumed.
///
/// Usage: `dart run tool/_challenge_lifetime_probe.dart <studentId> <password>`
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
    print('usage: dart run tool/_challenge_lifetime_probe.dart <id> <pass>');
    return;
  }
  final user = args[0];
  final pass = args[1];

  for (final wait in [0, 60, 180, 420]) {
    await _lifetime(user, pass, Duration(seconds: wait));
  }
}

/// Waits [wait], then answers the challenge fetched before the wait.
Future<void> _lifetime(String user, String pass, Duration wait) async {
  final transport = PortalTransport(baseUri: Uri.parse(_base));
  final client = CullinanPortalClient(transport: transport);
  final started = DateTime.now();
  try {
    final challenge = await client.beginLogin(user);
    final answer = CaptchaSolver().solve(challenge!.imageBytes).text!;
    final sessionId =
        transport.jars.jarFor(user).cookies['ASP.NET_SessionId'] ?? '?';

    if (wait > Duration.zero) {
      print('  waiting ${wait.inSeconds}s ...');
      await Future<void>.delayed(wait);
    }

    // Nothing else was requested, so the session id has not moved. The
    // challenge is answered exactly as it was fetched.
    final session = await client.completeLogin(
      username: user,
      password: pass,
      challenge: LoginChallengeResponse(answer),
    );
    final elapsed = DateTime.now().difference(started).inSeconds;
    print('  waited ${elapsed}s -> LOGIN OK '
        '(session id ${sessionId.substring(0, 8)}...)');
  } on LoginRejectedException catch (e) {
    final elapsed = DateTime.now().difference(started).inSeconds;
    print('  waited ${elapsed}s -> REFUSED: ${e.message}');
  } catch (e) {
    print('  ERROR: $e');
  } finally {
    transport.close();
  }
}
