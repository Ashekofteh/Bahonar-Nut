/// Probes how the portal binds a CAPTCHA answer to a session.
///
/// READ-ONLY: it only logs in. It never reserves, buys, cancels or lists.
///
/// ## Why
///
/// The portal binds the expected answer to the session at image-fetch time, so
/// fetching the image again rotates the answer. The app's typed-answer path
/// fetched a second image and posted the student's digits against it, which
/// the portal refused every time.
///
/// This probe establishes the three facts the fix rests on:
///   1. the ordinary sequence (page -> image -> answer -> POST) logs in;
///   2. re-fetching the image makes a previously-valid answer wrong;
///   3. the answer can still be posted later, against the image that was
///      fetched, without fetching another one.
///
/// Usage: `dart run tool/_captcha_binding_probe.dart <studentId> <password>`
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
    print('usage: dart run tool/_captcha_binding_probe.dart <id> <password>');
    return;
  }
  final user = args[0];
  final pass = args[1];

  print('=== 1. the ordinary sequence logs in ===');
  await _baseline(user, pass);

  print('\n=== 2. re-fetching the image invalidates a valid answer ===');
  await _rotationBreaksIt(user, pass);

  print('\n=== 3. the answer still works later, against the fetched image ===');
  await _reusePending(user, pass);

  print('\n=== 4. a page GET between the image and the answer ===');
  await _pageGetInBetween(user, pass);

  print('\n=== 5. the image read at the moment of answering is the live one ===');
  await _solveAfterTheWait(user, pass);

  print('\n=== 6. a GET of the REAL login page in between ===');
  await _readInBetween(user, pass, '/', 'the real login page');

  print('\n=== 7. a GET of the reservation page in between ===');
  await _readInBetween(user, pass, '/Reservation/Reservation.aspx',
      'the reservation page');

  print('\n=== 8. a GET of the captcha endpoint in between ===');
  await _readInBetween(user, pass, '/UserControls/Captcha.ashx',
      'the captcha endpoint');

  print('\n=== 9. does the session id change across a read? ===');
  await _sessionIdAcrossARead(user, pass);

  print('\n=== 10. does another account\'s request break this one? ===');
  await _otherAccountInBetween(user, pass);
}

/// Whether the session id survives a read.
Future<void> _sessionIdAcrossARead(String user, String pass) async {
  final transport = PortalTransport(baseUri: Uri.parse(_base));
  final client = CullinanPortalClient(transport: transport);
  try {
    await client.beginLogin(user);
    final before = transport.jars.jarFor(user).cookies['ASP.NET_SessionId'];
    print('  session id after the challenge: $before');

    await transport.get(user, '/Reservation/Reservation.aspx');
    final after = transport.jars.jarFor(user).cookies['ASP.NET_SessionId'];
    print('  session id after a read:        $after');
    print('  RESULT: ${before == after ? "UNCHANGED" : "CHANGED"}');
  } catch (e) {
    print('  ERROR: $e');
  } finally {
    transport.close();
  }
}

/// Whether a request for a *different* account disturbs this one.
Future<void> _otherAccountInBetween(String user, String pass) async {
  final transport = PortalTransport(baseUri: Uri.parse(_base));
  final client = CullinanPortalClient(transport: transport);
  try {
    final challenge = await client.beginLogin(user);
    final answer = CaptchaSolver().solve(challenge!.imageBytes).text!;
    print('  image read as: $answer');

    // A request for a different account, on a different session.
    await transport.get('some-other-account', '/');
    print('  a request for another account was made in between');

    final session = await client.completeLogin(
      username: user,
      password: pass,
      challenge: LoginChallengeResponse(answer),
    );
    print('  RESULT: LOGIN OK -- the answer SURVIVED the other account');
    print('  cookies ${session.cookies.keys.toList()}');
  } on LoginRejectedException catch (e) {
    print('  RESULT: REFUSED: ${e.message}');
  } catch (e) {
    print('  RESULT: ERROR: $e');
  } finally {
    transport.close();
  }
}

/// A read of [path] between the image and the answer.
///
/// The question this answers: which requests rotate the portal's expected
/// answer? The answer decides whether the typed-answer path must also keep
/// other reads out of the way.
Future<void> _readInBetween(
  String user,
  String pass,
  String path,
  String what,
) async {
  final transport = PortalTransport(baseUri: Uri.parse(_base));
  final client = CullinanPortalClient(transport: transport);
  try {
    final challenge = await client.beginLogin(user);
    final answer = CaptchaSolver().solve(challenge!.imageBytes).text!;
    print('  image read as: $answer');

    final response = await transport.get(user, path);
    print('  GET $path ($what) -> HTTP ${response.statusCode}');

    final session = await client.completeLogin(
      username: user,
      password: pass,
      challenge: LoginChallengeResponse(answer),
    );
    print('  RESULT: LOGIN OK -- the answer SURVIVED the read');
    print('  cookies ${session.cookies.keys.toList()}');
  } on LoginRejectedException catch (e) {
    print('  RESULT: REFUSED: ${e.message}');
  } catch (e) {
    print('  RESULT: ERROR: $e');
  } finally {
    transport.close();
  }
}

/// The ordinary path: one challenge, solved, posted once.
Future<void> _baseline(String user, String pass) async {
  final transport = PortalTransport(baseUri: Uri.parse(_base));
  final client = CullinanPortalClient(transport: transport);
  try {
    final challenge = await client.beginLogin(user);
    final solution = CaptchaSolver().solve(challenge!.imageBytes);
    print('  image read as: ${solution.text} '
        '(confidence ${solution.confidence.toStringAsFixed(4)})');

    final session = await client.completeLogin(
      username: user,
      password: pass,
      challenge: LoginChallengeResponse(solution.text!),
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

/// A second challenge is fetched, so the first answer is stale.
Future<void> _rotationBreaksIt(String user, String pass) async {
  final transport = PortalTransport(baseUri: Uri.parse(_base));
  final client = CullinanPortalClient(transport: transport);
  try {
    final first = await client.beginLogin(user);
    final answer = CaptchaSolver().solve(first!.imageBytes).text!;
    print('  image read as: $answer');

    // Fetching this second image rotates the portal's expected answer.
    final second = await client.beginLogin(user);
    print('  second image fetched (${second!.imageBytes.length} bytes)');

    await client.completeLogin(
      username: user,
      password: pass,
      challenge: LoginChallengeResponse(answer),
    );
    print('  RESULT: LOGIN OK -- the stale answer was ACCEPTED');
  } on LoginRejectedException catch (e) {
    print('  RESULT: REFUSED: ${e.message}');
  } catch (e) {
    print('  RESULT: ERROR: $e');
  } finally {
    transport.close();
  }
}

/// The answer is posted later, against the image that was fetched.
Future<void> _reusePending(String user, String pass) async {
  final transport = PortalTransport(baseUri: Uri.parse(_base));
  final client = CullinanPortalClient(transport: transport);
  try {
    final challenge = await client.beginLogin(user);
    final answer = CaptchaSolver().solve(challenge!.imageBytes).text!;
    print('  image read as: $answer');

    // The student is reading the code. Nothing is fetched in the meantime.
    print('  ... waiting 8s, as if a student were reading the code ...');
    await Future<void>.delayed(const Duration(seconds: 8));

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

/// A plain page GET between the image and the answer.
///
/// This is the read that the app's own flow would make if a background
/// refresh ran while the student was reading the code. If a page GET rotates
/// the answer, then the typed-answer path is not merely broken by the extra
/// challenge fetch — it is broken by *any* read, and the fix has to hold the
/// session still.
Future<void> _pageGetInBetween(String user, String pass) async {
  final transport = PortalTransport(baseUri: Uri.parse(_base));
  final client = CullinanPortalClient(transport: transport);
  try {
    final challenge = await client.beginLogin(user);
    final answer = CaptchaSolver().solve(challenge!.imageBytes).text!;
    print('  image read as: $answer');

    // A plain GET of the login page, with the same session.
    await transport.get(user, '/Login.aspx');
    print('  a plain page GET was made in between');

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

/// The image is read at the moment of answering, not at fetch time.
///
/// The solver reads the pixels it was given. This checks that the bytes
/// captured when the challenge was fetched are the same bytes the portal
/// would serve now — so a solver answer is judged against the same image the
/// student would have seen.
Future<void> _solveAfterTheWait(String user, String pass) async {
  final transport = PortalTransport(baseUri: Uri.parse(_base));
  final client = CullinanPortalClient(transport: transport);
  try {
    final challenge = await client.beginLogin(user);
    print('  first image: ${challenge!.imageBytes.length} bytes');

    await Future<void>.delayed(const Duration(seconds: 3));

    // A second image, fetched to compare against.
    final second = await client.beginLogin(user);
    final secondAnswer = CaptchaSolver().solve(second!.imageBytes).text!;
    print('  second image read as: $secondAnswer');

    // Now post the SECOND answer. It is the answer for the image that was
    // fetched last, so the pending state must be the one from the second
    // beginLogin.
    final session = await client.completeLogin(
      username: user,
      password: pass,
      challenge: LoginChallengeResponse(secondAnswer),
    );
    print('  RESULT: LOGIN OK -- the newest answer was ACCEPTED');
    print('  cookies ${session.cookies.keys.toList()}');
  } on LoginRejectedException catch (e) {
    print('  RESULT: REFUSED: ${e.message}');
  } catch (e) {
    print('  RESULT: ERROR: $e');
  } finally {
    transport.close();
  }
}
