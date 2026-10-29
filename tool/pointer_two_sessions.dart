/// Is the portal's **week pointer** per-session, or per-account?
///
/// This matters for the cancel's read-back. The adapter decides "the meal is
/// gone" by looking for the target's row on a page it read. If the page it
/// got does not carry that date, the row is *absent* — and "absent" is
/// indistinguishable from "cancelled" unless the app checks that the page
/// actually covers the date.
///
/// So: if the pointer is per-**account**, then a second session for the same
/// student (the web portal in another tab, or the app and a probe at once)
/// can move the pointer out from under a read, and a read that lands on the
/// wrong week sees no target row.
///
/// This logs in twice for the same account and reports what week each
/// session's GET answers with, and what a second next-week navigation gives.
///
/// Usage: `dart run tool/pointer_two_sessions.dart <studentId> <password>`
library;

// One-shot live probe tool: stdout printing is the entire point.
// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:bahonar_nut/transport/http_transport.dart';

const _base = 'https://nut.uk.ac.ir/';
const _reservation = '/Reservation/Reservation.aspx';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run tool/pointer_two_sessions.dart '
        '<studentId> <password>');
    return;
  }
  final user = args[0];
  final pass = args[1];

  final clock = SyncedServerClock();
  final transport = PortalTransport(baseUri: Uri.parse(_base), clock: clock);

  try {
    // ---- session A --------------------------------------------------------
    final a = await _login(transport, user, pass);
    print('session A: ${a.cookies['ASP.NET_SessionId']}');
    print('  A GET   -> ${_week(await transport.get(user, _reservation))}');
    final a1 = await transport.post(user, _reservation, body: {
      '__VIEWSTATE': _vs((await transport.get(user, _reservation)).body, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR':
          _vs((await transport.get(user, _reservation)).body, '__VIEWSTATEGENERATOR'),
      '__EVENTTARGET': r'ctl00$cphMain$imgbtnNextWeek',
      '__EVENTARGUMENT': '',
    });
    print('  A POST next -> ${_week(a1)}');

    // ---- session B, a second login for the SAME account -------------------
    final b = await _login(transport, user, pass);
    print('\nsession B: ${b.cookies['ASP.NET_SessionId']}');
    print('  B GET   -> ${_week(await transport.get(user, _reservation))}');

    // ---- now back to A ---------------------------------------------------
    print('\nback to A:');
    print('  A GET   -> ${_week(await transport.get(user, _reservation))}');

    // ---- and A navigates twice, then GETs --------------------------------
    final c1 = await transport.get(user, _reservation);
    final n1 = await transport.post(user, _reservation, body: {
      '__VIEWSTATE': _vs(c1.body, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': _vs(c1.body, '__VIEWSTATEGENERATOR'),
      '__EVENTTARGET': r'ctl00$cphMain$imgbtnNextWeek',
      '__EVENTARGUMENT': '',
    });
    print('  A POST next -> ${_week(n1)}');
    final n2 = await transport.post(user, _reservation, body: {
      '__VIEWSTATE': _vs(n1.body, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': _vs(n1.body, '__VIEWSTATEGENERATOR'),
      '__EVENTTARGET': r'ctl00$cphMain$imgbtnNextWeek',
      '__EVENTARGUMENT': '',
    });
    print('  A POST next -> ${_week(n2)}');
    print('  A GET   -> ${_week(await transport.get(user, _reservation))}');
  } catch (e, st) {
    print('EXCEPTION: $e');
    print(st.toString().split('\n').take(8).join('\n'));
  } finally {
    transport.close();
  }
}

Future<Session> _login(
  PortalTransport transport,
  String user,
  String pass,
) async {
  final page = await transport.get(user, '/');
  final captcha = await transport.getBytes(user, '/UserControls/Captcha.ashx');
  final solution = CaptchaSolver().solve(captcha);
  final login = await transport.post(user, '/', body: {
    '__VIEWSTATE': _vs(page.body, '__VIEWSTATE'),
    '__VIEWSTATEGENERATOR': _vs(page.body, '__VIEWSTATEGENERATOR'),
    '__VIEWSTATEENCRYPTED': '',
    'txtUsername': user,
    'txtPassword': pass,
    'txtCaptcha': solution.text!,
    'btnLogin': 'ورود سمت سرور ',
  });
  if (login.body.contains('txtUsernamePlain')) {
    throw StateError('LOGIN FAILED');
  }
  return Session(
    account: user,
    cookies: transport.jars.jarFor(user).cookies,
    establishedAt: DateTime.now().toUtc(),
  );
}

String _week(dynamic response) {
  final m = RegExp(r'id="[^"]*cphMain_lblWeekDate"[^>]*>(.*?)<',
          dotAll: true)
      .firstMatch(response.body as String);
  final t = m?.group(1)?.replaceAll(RegExp(r'\s+'), ' ').trim();
  return t == null ? '(none)' : t;
}

String _vs(String html, String id) {
  final m = RegExp('id="' + RegExp.escape(id) + r'"[^>]*value="([^"]*)"')
      .firstMatch(html);
  return m?.group(1) ?? '';
}
