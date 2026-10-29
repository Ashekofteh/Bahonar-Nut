/// READ-ONLY probe: does a fresh GET always return the **current** week, even
/// after a "next week" postback?
///
/// This matters because the write path decides which week to post against by
/// GETting the reservation page and asking whether it carries the target's
/// date. If the GET could return next week after a navigation, then a target
/// in the current week would look "not covered", and the client would
/// postback to next week — landing on the wrong week entirely.
///
/// Usage: `dart run tool/week_pointer.dart <studentId> <password>`
library;

// One-shot live probe tool: stdout printing is the entire point.
// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/transport/http_transport.dart';

const _base = 'https://nut.uk.ac.ir/';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run tool/week_pointer.dart <studentId> <password>');
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
      '__VIEWSTATEENCRYPTED': '',
      'txtUsername': user,
      'txtPassword': pass,
      'txtCaptcha': solution.text!,
      'btnLogin': 'ورود سمت سرور ',
    });
    if (login.body.contains('txtUsernamePlain')) {
      print('!! LOGIN FAILED');
      return;
    }
    print('login OK');

    // 1. The first GET of the reservation page.
    final get1 = await transport.get(user, '/Reservation/Reservation.aspx');
    print('\nGET #1   -> ${_week(get1.body)}');

    // 2. The next-week postback.
    final post = await transport.post(
      user,
      '/Reservation/Reservation.aspx',
      body: {
        '__VIEWSTATE': _input(get1.body, '__VIEWSTATE'),
        '__VIEWSTATEGENERATOR': _input(get1.body, '__VIEWSTATEGENERATOR'),
        '__EVENTTARGET': 'ctl00\$cphMain\$imgbtnNextWeek',
        '__EVENTARGUMENT': '',
      },
    );
    print('POST next -> ${_week(post.body)}');

    // 3. The critical question: does a fresh GET go back to the current week?
    final get2 = await transport.get(user, '/Reservation/Reservation.aspx');
    print('GET #2   -> ${_week(get2.body)}');

    // 4. And again, to be sure it is stable rather than alternating.
    final get3 = await transport.get(user, '/Reservation/Reservation.aspx');
    print('GET #3   -> ${_week(get3.body)}');

    print('\nheld rows per week:');
    for (final entry in {
      'GET#1': get1.body,
      'POST': post.body,
      'GET#2': get2.body,
      'GET#3': get3.body,
    }.entries) {
      print('   ${entry.key}: ${_heldLabels(entry.value).join('  ')}');
    }
  } catch (e, st) {
    print('EXCEPTION: $e');
    print(st.toString().split('\n').take(8).join('\n'));
  } finally {
    transport.close();
  }
}

/// The week a page shows, as the portal labels it.
String _week(String html) =>
    _byId(html, 'cphMain_lblWeekDate') ?? '(no week label)';

/// The labels of the rows that carry a green "reserved" icon.
List<String> _heldLabels(String html) {
  final out = <String>[];
  for (final m in RegExp(r'<img[^>]*src="[^"]*AcceptGreen16[^"]*"[^>]*>',
          dotAll: true)
      .allMatches(html)) {
    final tag = m.group(0)!;
    final id = RegExp(r'id="([^"]*)"').firstMatch(tag)?.group(1) ?? '';
    final row = RegExp(r'<tr[^>]*>(?:(?!</tr>).)*$', dotAll: true)
        .firstMatch(html.substring(0, m.start))
        ?.group(0);
    final label = row == null
        ? ''
        : (RegExp(r'<td[^>]*>([^<]*)</td>')
                .firstMatch(row)
                ?.group(1)
                ?.trim() ??
            '');
    out.add('${id.split('_').take(2).join('_')}:$label');
  }
  return out;
}

String _byId(String html, String id) {
  final m = RegExp('id="[^"]*' + RegExp.escape(id) + r'"[^>]*>(.*?)<',
          dotAll: true)
      .firstMatch(html);
  final t = m?.group(1)?.replaceAll(RegExp(r'\s+'), ' ').trim();
  return (t == null || t.isEmpty) ? '' : t;
}

String _input(String html, String id) {
  final m = RegExp('id="' + RegExp.escape(id) + r'"[^>]*value="([^"]*)"')
      .firstMatch(html);
  return m?.group(1) ?? '';
}
