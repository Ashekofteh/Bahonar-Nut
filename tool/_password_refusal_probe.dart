/// Prints what the portal says when it refuses the **password**.
///
/// READ-ONLY: it only logs in.
///
/// ## Why
///
/// On the device, a correct typed CAPTCHA was refused and no second
/// CAPTCHA dialog appeared — so the portal's refusal did **not** contain
/// «کد امنیتی», and the app classified it as a credential or network
/// failure. Which of the two it was decides the fix: a wrong password is
/// the student's, a network error is the app's.
///
/// This probe posts a correct CAPTCHA with a deliberately wrong password,
/// and prints the label the portal rendered.
///
/// Usage: `dart run tool/_password_refusal_probe.dart <studentId> <password>`
// Diagnostic CLI tool: stdout printing is the entire point.
// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings

library;

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/transport/html_parsing.dart';
import 'package:bahonar_nut/transport/http_transport.dart';

const _base = 'https://nut.uk.ac.ir/';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run tool/_password_refusal_probe.dart <id> <pass>');
    return;
  }
  final user = args[0];
  final pass = args[1];

  final transport = PortalTransport(baseUri: Uri.parse(_base));
  try {
    for (final attempt in <(String, String?)>[
      ('a correct code, a wrong password', 'not-the-password'),
      ('a wrong code, a correct password', null),
    ]) {
      // The solver declines on some images, so a fresh one is fetched until
      // it reads one — a challenge the solver cannot read says nothing
      // about the portal's refusal.
      String? solved;
      String? sessionId;
      String viewState = '';
      String generator = '';
      var declined = 0;
      for (var i = 0; i < 8 && solved == null; i++) {
        final page = await transport.get(user, '/');
        final image = await transport.getBytes(user, '/UserControls/Captcha.ashx');
        sessionId = transport.jars.jarFor(user).cookies['ASP.NET_SessionId'];
        viewState = hiddenFieldValue(page.body, '__VIEWSTATE') ?? '';
        generator = hiddenFieldValue(page.body, '__VIEWSTATEGENERATOR') ?? '';
        solved = CaptchaSolver().solve(image).text;
        if (solved == null) declined++;
      }
      if (solved == null) {
        print('[${attempt.$1}] the solver could not read any image '
            '($declined declined)');
        continue;
      }
      final code = attempt.$2 ?? '9999';
      final password = attempt.$2 ?? pass;

      transport.jars.jarFor(user).setCookie('ASP.NET_SessionId=$sessionId');
      final response = await transport.post(user, '/', body: {
        '__VIEWSTATE': viewState,
        '__VIEWSTATEGENERATOR': generator,
        '__EVENTTARGET': '',
        '__EVENTARGUMENT': '',
        'txtUsername': user,
        'txtPassword': password,
        'btnLogin': 'ورود سمت سرور ',
        'txtCaptcha': code,
      });

      final error = labelText(response.body, 'lblLoginError');
      print('[${attempt.$1}]');
      print('   code posted: $code   password: '
          '${attempt.$2 == null ? 'correct' : 'wrong'}');
      print('   lblLoginError: ${error == null ? "(absent)" : error}');
      print('   contains «کد امنیتی»: ${response.body.contains('کد امنیتی')}');
    }
  } catch (e, st) {
    print('EXCEPTION: $e');
    print(st.toString().split('\n').take(6).join('\n'));
  } finally {
    transport.close();
  }
}
