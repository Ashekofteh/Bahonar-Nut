/// READ-ONLY probe: how many weeks ahead does the portal let a student book?
///
/// This decides how deep the app's reservation read has to go. If the rows in
/// the third week are editable, a student can hold a meal three weeks out and
/// a two-week read would still miss it.
///
/// Usage: `dart run tool/week_horizon.dart <studentId> <password>`
library;

// One-shot live probe tool: stdout printing is the entire point.
// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/core/persian.dart';
import 'package:bahonar_nut/transport/html_parsing.dart';
import 'package:bahonar_nut/transport/http_transport.dart';

const _base = 'https://nut.uk.ac.ir/';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run tool/week_horizon.dart <studentId> <password>');
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

    var html = login.body;

    // What week-navigation controls does the page offer?
    print('\nweek navigation controls:');
    for (final m in RegExp(
            r'<(?:input|a)[^>]*(?:imgbtnNextWeek|imgbtnPrevWeek|NextWeek|PrevWeek)[^>]*>',
            dotAll: true)
        .allMatches(html)) {
      print('   ${_text(m.group(0)!)}');
    }

    for (var week = 0; week <= 3; week++) {
      print('\nWEEK $week  ${_week(html)}');
      for (final slot in ['grdReservationBreakfast', 'grdReservationLunch']) {
        final rows = tableRows(html, slot);
        if (rows.isEmpty) {
          print('   $slot: no rows');
          continue;
        }
        var editable = 0;
        var locked = 0;
        final labels = <String>[];
        for (final row in rows) {
          if (row.cells.length < 7) continue;
          final date = parseJalaliDate(row.cell(1));
          final checkbox = inputBySuffix(row.raw, 'chkReserve');
          final disabled = checkbox?.disabled ?? false;
          if (disabled) {
            locked++;
          } else {
            editable++;
          }
          labels.add('${date == null ? "?" : date.toIso8601String().substring(0, 10)}'
              '${disabled ? "[X]" : "[o]"}');
        }
        print('   $slot: ${rows.length} rows, $editable editable, $locked locked');
        print('      ${labels.join(" ")}');
      }

      final next = await transport.post(
        user,
        '/Reservation/Reservation.aspx',
        body: {
          '__VIEWSTATE': _input(html, '__VIEWSTATE'),
          '__VIEWSTATEGENERATOR': _input(html, '__VIEWSTATEGENERATOR'),
          '__EVENTTARGET': 'ctl00\$cphMain\$imgbtnNextWeek',
          '__EVENTARGUMENT': '',
        },
      );
      html = next.body;
    }
  } catch (e, st) {
    print('EXCEPTION: $e');
    print(st.toString().split('\n').take(8).join('\n'));
  } finally {
    transport.close();
  }
}

String _week(String html) =>
    _byId(html, 'cphMain_lblWeekDate') ?? '(no label)';

String _text(String html) => html
    .replaceAll(RegExp(r'<[^>]*>'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

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
