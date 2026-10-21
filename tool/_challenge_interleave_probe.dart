/// Probes what a CAPTCHA answer needs, when another login happens in between.
///
/// READ-ONLY: it only logs in.
///
/// ## Why
///
/// F77 established that the answer is bound to the `ASP.NET_SessionId` that
/// was current when the image was fetched, and that restoring that id makes
/// the answer valid again.
///
/// This probe asks the remaining question: what if **another login** happens
/// while the student is reading the code? A second login fetches a new page
/// (new viewstate) and a new image, and replaces the pending login.
///
/// If the answer survives, the challenge only needs the session id. If it does
/// not, the viewstate has to travel with it as well.
///
/// Usage: `dart run tool/_challenge_interleave_probe.dart <studentId> <password>`
// Diagnostic CLI tool: stdout printing is the entire point.
// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings

library;

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/transport/html_parsing.dart';
import 'package:bahonar_nut/transport/http_transport.dart';

const _base = 'https://nut.uk.ac.ir/';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run tool/_challenge_interleave_probe.dart <id> <pass>');
    return;
  }
  final user = args[0];
  final pass = args[1];

  print('=== A. the original viewstate, with the original session id ===');
  await _interleaved(user, pass, useOriginalViewState: true);

  print('\n=== B. the NEW viewstate, with the original session id ===');
  await _interleaved(user, pass, useOriginalViewState: false);
}

/// Fetches a challenge, lets a second login happen, then answers.
Future<void> _interleaved(
  String user,
  String pass, {
  required bool useOriginalViewState,
}) async {
  final transport = PortalTransport(baseUri: Uri.parse(_base));
  final account = user;
  try {
    // --- The first login: page, image, answer ---
    final firstPage = await transport.get(account, '/');
    final firstViewState = hiddenFieldValue(firstPage.body, '__VIEWSTATE');
    final firstGenerator =
        hiddenFieldValue(firstPage.body, '__VIEWSTATEGENERATOR');
    final firstSessionId =
        transport.jars.jarFor(account).cookies['ASP.NET_SessionId'];
    final image = await transport.getBytes(account, '/UserControls/Captcha.ashx');
    final answer = CaptchaSolver().solve(image).text!;
    print('  image read as: $answer');
    print('  session id at fetch time: $firstSessionId');

    // --- A second login happens while the student is reading ---
    final secondPage = await transport.get(account, '/');
    final secondViewState = hiddenFieldValue(secondPage.body, '__VIEWSTATE');
    final secondSessionId =
        transport.jars.jarFor(account).cookies['ASP.NET_SessionId'];
    print('  a second login happened, session id now: $secondSessionId');

    // --- Restore the session the answer is bound to ---
    transport.jars
        .jarFor(account)
        .setCookie('ASP.NET_SessionId=$firstSessionId');
    print('  the original session id was restored');

    final viewState = useOriginalViewState ? firstViewState : secondViewState;
    final generator =
        useOriginalViewState ? firstGenerator : hiddenFieldValue(
              secondPage.body,
              '__VIEWSTATEGENERATOR',
            );
    print('  posting with the '
        '${useOriginalViewState ? "ORIGINAL" : "NEW"} viewstate');

    final response = await transport.post(account, '/', body: {
      '__VIEWSTATE': viewState,
      '__VIEWSTATEGENERATOR': generator,
      '__VIEWSTATEENCRYPTED': '',
      '__EVENTTARGET': '',
      '__EVENTARGUMENT': '',
      'txtUsername': user,
      'txtPassword': pass,
      'btnLogin': 'ورود سمت سرور ',
      'txtCaptcha': answer,
    });

    final error = labelText(response.body, 'lblLoginError');
    if (response.looksLikeLoginPage || error != null) {
      print('  RESULT: REFUSED: ${error ?? 'the login page came back'}');
    } else {
      print('  RESULT: LOGIN OK');
      print('  cookies ${transport.jars.jarFor(account).cookies.keys.toList()}');
      final nowId =
          transport.jars.jarFor(account).cookies['ASP.NET_SessionId'];
      print('  session id after login: $nowId'
          '${nowId == firstSessionId ? "  (UNCHANGED - suspicious)" : ""}');
    }
  } catch (e) {
    print('  ERROR: $e');
  } finally {
    transport.close();
  }
}

/// Keeps the linter honest about the unused import.
AccountId? _unused(AccountId id) => id;
