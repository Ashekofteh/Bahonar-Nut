/// Prints what the portal says when it refuses a login.
///
/// READ-ONLY: it only logs in, and it never books, buys or cancels.
///
/// ## Why
///
/// On the device, a correct typed CAPTCHA was refused and the app reported
/// «کد امنیتی به‌صورت خودکار خوانده نشد.» — the *first* sync's error, not
/// the refusal's. So two things are unknown:
///   * what the portal's own error label says for a wrong code, and
///   * whether the app would even classify it as a CAPTCHA refusal (it
///     matches on «کد امنیتی»).
///
/// This probe answers both, by posting a deliberately wrong code and
/// printing the label the portal rendered — plus the field names the login
/// form actually carries, in case the app is posting the wrong one.
///
/// Usage: `dart run tool/_login_refusal_probe.dart <studentId> <password>`
// Diagnostic CLI tool: stdout printing is the entire point.
// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings

library;

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/transport/html_parsing.dart';
import 'package:bahonar_nut/transport/http_transport.dart';

const _base = 'https://nut.uk.ac.ir/';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run tool/_login_refusal_probe.dart <id> <pass>');
    return;
  }
  final user = args[0];
  final pass = args[1];

  final transport = PortalTransport(baseUri: Uri.parse(_base));
  try {
    // --- The login page, and the fields it carries ---
    final page = await transport.get(user, '/');
    final viewState = hiddenFieldValue(page.body, '__VIEWSTATE') ?? '';
    final generator = hiddenFieldValue(page.body, '__VIEWSTATEGENERATOR') ?? '';
    print('--- the login form ---');
    print('viewstate length: ${viewState.length}');
    for (final name in ['txtUsername', 'txtPassword', 'txtCaptcha', 'btnLogin']) {
      print('  field "$name" present: ${page.body.contains('"$name"')}');
    }

    // --- The challenge, in the session the page left behind ---
    final image = await transport.getBytes(user, '/UserControls/Captcha.ashx');
    final sessionId =
        transport.jars.jarFor(user).cookies['ASP.NET_SessionId'];
    print('\nsession after the page: $sessionId');
    print('captcha bytes: ${image.length}');

    final solved = CaptchaSolver().solve(image).text;
    print('solver read: $solved');

    // --- A deliberately wrong code, in the right session ---
    final wrong = (solved ?? '1234') == '9999' ? '8888' : '9999';
    print('\n=== A. a wrong code, posted in the right session ===');
    await _post(
      transport,
      user,
      pass,
      wrong,
      sessionId,
      viewState,
      generator,
      label: 'wrong code',
    );

    // --- A wrong code, in a rotated session ---
    print('\n=== B. a wrong code, posted in a rotated session ===');
    final rotated = await transport.get(user, '/');
    final rotatedSession =
        transport.jars.jarFor(user).cookies['ASP.NET_SessionId'];
    final rotatedViewState =
        hiddenFieldValue(rotated.body, '__VIEWSTATE') ?? '';
    final rotatedGenerator =
        hiddenFieldValue(rotated.body, '__VIEWSTATEGENERATOR') ?? '';
    print('rotated session: $rotatedSession');
    await _post(
      transport,
      user,
      pass,
      wrong,
      rotatedSession,
      rotatedViewState,
      rotatedGenerator,
      label: 'rotated session',
    );

    // --- A correct code, in the right session ---
    if (solved != null) {
      print('\n=== C. the correct code, posted in the right session ===');
      final page3 = await transport.get(user, '/');
      final image3 = await transport.getBytes(user, '/UserControls/Captcha.ashx');
      final session3 =
          transport.jars.jarFor(user).cookies['ASP.NET_SessionId'];
      final solved3 = CaptchaSolver().solve(image3).text;
      print('solver read: $solved3   session: $session3');
      await _post(
        transport,
        user,
        pass,
        solved3 ?? '0000',
        session3,
        hiddenFieldValue(page3.body, '__VIEWSTATE') ?? '',
        hiddenFieldValue(page3.body, '__VIEWSTATEGENERATOR') ?? '',
        label: 'correct code',
      );
    }
  } catch (e, st) {
    print('EXCEPTION: $e');
    print(st.toString().split('\n').take(6).join('\n'));
  } finally {
    transport.close();
  }
}

/// Posts a login and prints what the portal answered.
Future<void> _post(
  PortalTransport transport,
  String user,
  String pass,
  String code,
  String? sessionId,
  String viewState,
  String generator, {
  required String label,
}) async {
  if (sessionId != null) {
    transport.jars.jarFor(user).setCookie('ASP.NET_SessionId=$sessionId');
  }
  final response = await transport.post(user, '/', body: {
    '__VIEWSTATE': viewState,
    '__VIEWSTATEGENERATOR': generator,
    '__EVENTTARGET': '',
    '__EVENTARGUMENT': '',
    'txtUsername': user,
    'txtPassword': pass,
    'btnLogin': 'ورود سمت سرور ',
    'txtCaptcha': code,
  });

  final error = labelText(response.body, 'lblLoginError');
  print('[$label] status: ${response.statusCode}');
  print('[$label] looks like the login page: '
      '${response.looksLikeLoginPage}');
  print('[$label] lblLoginError: ${error == null ? "(absent)" : error}');
  print('[$label] contains «کد امنیتی»: '
      '${response.body.contains('کد امنیتی')}');
  if (error == null && response.looksLikeLoginPage) {
    // The portal rendered the login page without a label. Whatever it says
    // has to be found in the markup, so the visible text is printed.
    final snippet = _visibleText(response.body);
    print('[$label] page text: $snippet');
  }
}

/// The page's visible text, roughly.
String _visibleText(String html) {
  final withoutScripts = html
      .replaceAll(RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'<[^>]+>'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return withoutScripts.length > 900
      ? withoutScripts.substring(0, 900)
      : withoutScripts;
}
