/// Probes whether a stale session id can still carry a valid CAPTCHA answer.
///
/// READ-ONLY: it only logs in.
///
/// ## Why
///
/// The portal issues a new `ASP.NET_SessionId` on every page GET, and the
/// CAPTCHA endpoint sets none. So the answer is bound to the session id that
/// was current when the image was fetched, and any intervening request
/// replaces it.
///
/// The question this answers decides the shape of the fix: if posting the
/// answer with the **original** session id still works, then the fix is to
/// carry that id with the challenge, and an interleaved read is harmless. If
/// it does not work, the fix must also keep other requests out of the way
/// while the student reads the code.
///
/// Usage: `dart run tool/_session_restore_probe.dart <studentId> <password>`
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
    print('usage: dart run tool/_session_restore_probe.dart <id> <password>');
    return;
  }
  final user = args[0];
  final pass = args[1];

  print('=== A. no intervening request, no restore ===');
  await _plain(user, pass);

  print('\n=== B. an intervening read, then restore the original session id ===');
  await _readThenRestore(user, pass);

  print('\n=== C. an intervening read, then restore AND wait 8s ===');
  await _readThenRestore(user, pass, wait: const Duration(seconds: 8));

  print('\n=== D. TWO intervening reads, then restore ===');
  await _twoReadsThenRestore(user, pass);

  print('\n=== E. restore only the session id, not the other cookies ===');
  await _restoreSessionIdOnly(user, pass);
}

/// Two reads, then the original session id is restored.
Future<void> _twoReadsThenRestore(String user, String pass) async {
  final transport = PortalTransport(baseUri: Uri.parse(_base));
  final client = CullinanPortalClient(transport: transport);
  try {
    final challenge = await client.beginLogin(user);
    final answer = CaptchaSolver().solve(challenge!.imageBytes).text!;
    print('  image read as: $answer');

    final original = Map<String, String>.from(
      transport.jars.jarFor(user).cookies,
    );
    print('  session id at fetch time: ${original['ASP.NET_SessionId']}');

    await transport.get(user, '/Reservation/Reservation.aspx');
    await transport.get(user, '/Reservation/Reservation.aspx');
    print('  two reads done, session id now: '
        '${transport.jars.jarFor(user).cookies['ASP.NET_SessionId']}');

    transport.jars.jarFor(user).replaceAll(original);
    print('  original session id restored');

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

/// Only the session id is restored; the other cookies keep their newest values.
Future<void> _restoreSessionIdOnly(String user, String pass) async {
  final transport = PortalTransport(baseUri: Uri.parse(_base));
  final client = CullinanPortalClient(transport: transport);
  try {
    final challenge = await client.beginLogin(user);
    final answer = CaptchaSolver().solve(challenge!.imageBytes).text!;
    print('  image read as: $answer');

    final originalId =
        transport.jars.jarFor(user).cookies['ASP.NET_SessionId']!;
    print('  session id at fetch time: $originalId');

    await transport.get(user, '/Reservation/Reservation.aspx');
    print('  session id now: '
        '${transport.jars.jarFor(user).cookies['ASP.NET_SessionId']}');

    // Put back only the session id; leave keyId and the rest as they are.
    transport.jars.jarFor(user).setCookie('ASP.NET_SessionId=$originalId');
    print('  only the session id restored');

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

/// The baseline: fetch, solve, post. No restore, no wait.
Future<void> _plain(String user, String pass) async {
  final transport = PortalTransport(baseUri: Uri.parse(_base));
  final client = CullinanPortalClient(transport: transport);
  try {
    final challenge = await client.beginLogin(user);
    final answer = CaptchaSolver().solve(challenge!.imageBytes).text!;
    print('  image read as: $answer');

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

/// An intervening read rotates the session id; the original is restored.
Future<void> _readThenRestore(
  String user,
  String pass, {
  Duration wait = Duration.zero,
}) async {
  final transport = PortalTransport(baseUri: Uri.parse(_base));
  final client = CullinanPortalClient(transport: transport);
  try {
    final challenge = await client.beginLogin(user);
    final answer = CaptchaSolver().solve(challenge!.imageBytes).text!;
    print('  image read as: $answer');

    // The cookies as they stand right now — the ones the answer is bound to.
    final original = Map<String, String>.from(
      transport.jars.jarFor(user).cookies,
    );
    print('  session id at fetch time: ${original['ASP.NET_SessionId']}');

    // Something else makes a request with this account, and the portal
    // answers with a new session id.
    await transport.get(user, '/Reservation/Reservation.aspx');
    final rotated = transport.jars.jarFor(user).cookies['ASP.NET_SessionId'];
    print('  session id after the read: $rotated');

    if (wait > Duration.zero) {
      print('  ... waiting ${wait.inSeconds}s ...');
      await Future<void>.delayed(wait);
    }

    // Put the original session back, so the POST is judged against the
    // session the image was fetched in.
    transport.jars.jarFor(user).replaceAll(original);
    print('  original session id restored');

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
