/// Probes whether a second image fetch replaces the challenge in the session.
///
/// READ-ONLY: it only logs in.
///
/// ## Why
///
/// F77 established that the answer is bound to the session id that was current
/// when the image was fetched. The open question is finer than that: if the
/// CAPTCHA endpoint is hit **twice** in the same session, is the challenge
/// still the first image, or the second?
///
/// It matters for two reasons. The app's fix assumes the challenge is stable
/// in its session until it is answered — if a second fetch replaced it, the
/// student's image would be stale. And three of the diagnostic tools fetch
/// the image a second time, so the answer they post is for the second image
/// while the session holds the first.
///
/// Usage: `dart run tool/_double_fetch_probe.dart <studentId> <password>`
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
    print('usage: dart run tool/_double_fetch_probe.dart <id> <password>');
    return;
  }
  final user = args[0];
  final pass = args[1];

  print('=== A. answer for the FIRST image, after a second fetch ===');
  await _double(user, pass, answerTheFirst: true);

  print('\n=== B. answer for the SECOND image, after a second fetch ===');
  await _double(user, pass, answerTheFirst: false);
}

/// Fetches the image twice in one session, then answers one of them.
Future<void> _double(
  String user,
  String pass, {
  required bool answerTheFirst,
}) async {
  final transport = PortalTransport(baseUri: Uri.parse(_base));
  final client = CullinanPortalClient(transport: transport);
  try {
    // The first image, from beginLogin.
    final challenge = await client.beginLogin(user);
    final firstAnswer = CaptchaSolver().solve(challenge!.imageBytes).text!;
    print('  first image read as:  $firstAnswer');

    // The second image, fetched from the same session.
    final secondBytes =
        await transport.getBytes(user, '/UserControls/Captcha.ashx');
    final secondAnswer = CaptchaSolver().solve(secondBytes).text!;
    print('  second image read as: $secondAnswer');

    final answer = answerTheFirst ? firstAnswer : secondAnswer;
    print('  posting the answer for the '
        '${answerTheFirst ? "FIRST" : "SECOND"} image');

    final session = await client.completeLogin(
      username: user,
      password: pass,
      challenge: LoginChallengeResponse(answer),
    );
    print('  RESULT: LOGIN OK, cookies ${session.cookies.keys.toList()}');
  } on LoginRejectedException catch (e) {
    print('  RESULT: REFUSED: ${e.message}');
  } catch (e) {
    print('  RESULT: ERROR: $e');
  } finally {
    transport.close();
  }
}
