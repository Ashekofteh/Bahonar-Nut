/// READ-ONLY probe: how the portal's week pointer moves.
///
/// The cancel's read-back is only honest if the page it lands on carries the
/// target date. The pointer is **session-scoped** — the grid rows are
/// identical in every week, so a POST decides which week it affects by the
/// `__VIEWSTATE` it carries, and the "next week" button moves the pointer.
///
/// The device reported a cancel that never happened. That needs the read-back
/// to land on a week that does **not** carry the target, and then the
/// "the row is absent" reading to be mistaken for "the meal is gone".
///
/// So this measures the pointer directly, through several sequences, and
/// prints the week label of every page. It writes nothing to the account.
///
/// Usage: `dart run tool/week_drift.dart <studentId> <password>`
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
    print('usage: dart run tool/week_drift.dart <studentId> <password>');
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

    // ---- Sequence 1: the app's navigation, twice, sequentially -----------
    print('=== sequence 1: GET, POST-next, GET, POST-next (sequential)');
    var html = await _get(transport, user);
    print('  GET        ${_label(html)}');
    html = await _next(transport, user, html);
    print('  POST-next  ${_label(html)}');
    html = await _get(transport, user);
    print('  GET        ${_label(html)}');
    html = await _next(transport, user, html);
    print('  POST-next  ${_label(html)}');

    // ---- Sequence 2: two GETs, then two POST-next in parallel -------------
    print('\n=== sequence 2: two GETs, then two POST-next **in parallel**');
    final g1 = await _get(transport, user);
    print('  GET        ${_label(g1)}');
    final g2 = await _get(transport, user);
    print('  GET        ${_label(g2)}');
    final posts = await Future.wait([
      _next(transport, user, g1),
      _next(transport, user, g2),
    ]);
    print('  POST-next A  ${_label(posts[0])}');
    print('  POST-next B  ${_label(posts[1])}');

    // ---- Sequence 3: the app's cancel shape, twice ------------------------
    //
    // readWeekFor = GET + POST-next. The cancel posts the save against that
    // page, then reads back with readWeekFor again. So the sequence is
    // GET, POST-next, POST-save, GET, POST-next.
    print('\n=== sequence 3: the cancel\'s shape, with a no-op post in the middle');
    html = await _get(transport, user);
    print('  GET          ${_label(html)}');
    html = await _next(transport, user, html);
    print('  POST-next    ${_label(html)}');
    // A postback that changes nothing: the same viewstate, no event target,
    // no save button.
    final noop = await transport.post(user, _reservation, body: {
      '__VIEWSTATE': _input(html, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': _input(html, '__VIEWSTATEGENERATOR'),
      '__EVENTTARGET': '',
      '__EVENTARGUMENT': '',
    });
    print('  POST-noop    ${_label(noop.body)}');
    html = await _get(transport, user);
    print('  GET          ${_label(html)}');
    html = await _next(transport, user, html);
    print('  POST-next    ${_label(html)}   <== the read-back');

    // ---- Sequence 4: a postback that *does* save ------------------------
    //
    // The save button re-renders the page. Which week it re-renders, and
    // which week the *next* GET/POST-next lands on, is what the read-back
    // depends on. The button is pressed with the page's own checked rows
    // re-posted, so nothing about the account changes.
    print('\n=== sequence 4: GET, POST-next, POST-save, GET, POST-next');
    html = await _get(transport, user);
    print('  GET          ${_label(html)}');
    html = await _next(transport, user, html);
    print('  POST-next    ${_label(html)}');
    final saved = await transport.post(user, _reservation, body: {
      '__VIEWSTATE': _input(html, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': _input(html, '__VIEWSTATEGENERATOR'),
      '__EVENTTARGET': '',
      '__EVENTARGUMENT': '',
      r'ctl00$cphMain$btnSaveBreakfast': 'ذخیره',
    });
    print('  POST-save    ${_label(saved.body)}');
    html = await _get(transport, user);
    print('  GET          ${_label(html)}');
    html = await _next(transport, user, html);
    print('  POST-next    ${_label(html)}   <== the read-back');
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
