/// READ-ONLY probe: does a second "next week" navigation advance the pointer
/// again, landing on week 2?
///
/// `week_drift.dart` showed that two **parallel** next-week posts both land
/// on week 1 — because both start from the same week-0 viewstate. But if the
/// pointer is **session-scoped and cumulative**, then two **sequential**
/// next-week posts land on week 1 and then week 2.
///
/// That is exactly what two overlapping app operations produce: each does
/// GET, POST-next; the first POST-next moves the pointer to week 1, and the
/// second moves it to week 2 — a week whose rows are all `disabled` and which
/// therefore carries no target row at all.
///
/// Usage: `dart run tool/week_double.dart <studentId> <password>`
library;

// One-shot live probe tool: stdout printing is the entire point.
// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/transport/http_transport.dart';

const _base = 'https://nut.uk.ac.ir/';
const _reservation = '/Reservation/Reservation.aspx';
const _nextWeek = r'ctl00$cphMain$imgbtnNextWeek';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run tool/week_double.dart <studentId> <password>');
    return;
  }
  final user = args[0];
  final pass = args[1];

  final transport = PortalTransport(baseUri: Uri.parse(_base));

  try {
    final page = await transport.get(user, '/');
    final captcha = await transport.getBytes(user, '/UserControls/Captcha.ashx');
    final solution = CaptchaSolver().solve(captcha);
    final login = await transport.post(user, '/', body: {
      '__VIEWSTATE': _input(page.body, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': _input(page.body, '__VIEWSTATEGENERATOR'),
      '__EVENTVALIDATION': '',
      'txtUsername': user,
      'txtPassword': pass,
      'txtCaptcha': solution.text!,
      'btnLogin': 'ورود سمت سرور ',
    });
    if (login.body.contains('txtUsernamePlain')) {
      print('!! LOGIN FAILED');
      return;
    }
    print('login OK\n');

    // ---- Two GETs, then two SEQUENTIAL next-week posts -------------------
    print('=== two GETs, then two SEQUENTIAL POST-next');
    var a = await _get(transport, user);
    print('  GET          ${_label(a)}');
    var b = await _get(transport, user);
    print('  GET          ${_label(b)}');
    a = await _next(transport, user, a);
    print('  POST-next 1  ${_label(a)}');
    b = await _next(transport, user, b);
    print('  POST-next 2  ${_label(b)}   <== the second one');

    // ---- Two GETs, then four SEQUENTIAL next-week posts -----------------
    print('\n=== two GETs, then four SEQUENTIAL POST-next');
    var c = await _get(transport, user);
    var d = await _get(transport, user);
    for (var i = 1; i <= 4; i++) {
      c = await _next(transport, user, c);
      print('  POST-next $i  ${_label(c)}');
    }

    // ---- Does a GET reset the pointer? ----------------------------------
    print('\n=== after the walks, a plain GET');
    final after = await _get(transport, user);
    print('  GET          ${_label(after)}');
  } catch (e, st) {
    print('EXCEPTION: $e');
    print(st.toString().split('\n').take(8).join('\n'));
  } finally {
    transport.close();
  }
}

Future<String> _get(PortalTransport transport, String user) async {
  final response = await transport.get(user, _reservation);
  return response.body;
}

Future<String> _next(
  PortalTransport transport,
  String user,
  String html,
) async {
  final response = await transport.post(user, _reservation, body: {
    '__VIEWSTATE': _input(html, '__VIEWSTATE'),
    '__VIEWSTATEGENERATOR': _input(html, '__VIEWSTATEGENERATOR'),
    '__EVENTTARGET': _nextWeek,
    '__EVENTARGUMENT': '',
  });
  return response.body;
}

/// The page's own week label, e.g. `1405/07/25 الی 1405/08/01`.
String _label(String html) {
  final m = RegExp(r'id="[^"]*lblWeekDate"[^>]*>(.*?)<', dotAll: true)
      .firstMatch(html);
  final text = m?.group(1)?.replaceAll(RegExp(r'\s+'), ' ').trim();
  return text == null || text.isEmpty ? '(no label)' : '"$text"';
}

String _input(String html, String id) {
  final m = RegExp('id="' + RegExp.escape(id) + r'"[^>]*value="([^"]*)"')
      .firstMatch(html);
  return m?.group(1) ?? '';
}
