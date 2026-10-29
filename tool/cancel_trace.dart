/// READ-ONLY trace of the cancel path's week navigation.
///
/// The app's cancel reported success while the portal still held the meal.
/// The adapter decides success by reading the portal back and asking "is the
/// meal still there?" — so a **false negative** in that read is enough to
/// report a cancel that never happened.
///
/// The read asks the *page* whether the row is held, and returns "not held"
/// when the row is **absent** from the page. So the read is only as good as
/// the page it was given: if the navigation lands on the wrong week, the row
/// is not there, and the meal reads as gone.
///
/// This walks the same navigation the cancel does — and nothing else — and
/// prints the week each page belongs to, so the drift is visible.
///
/// Usage: `dart run tool/cancel_trace.dart <studentId> <password>`
library;

// One-shot live probe tool: stdout printing is the entire point.
// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/adapter/cullinan_parser.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/persian.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:bahonar_nut/transport/html_parsing.dart';
import 'package:bahonar_nut/transport/http_transport.dart';

const _base = 'https://nut.uk.ac.ir/';
const _reservation = '/Reservation/Reservation.aspx';

/// The next-week meal: 1405/08/03 = 2026-10-25, breakfast.
final _target = DateTime.utc(2026, 10, 25);
const _targetSlot = MealSlot.breakfast;

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run tool/cancel_trace.dart <studentId> <password>');
    return;
  }
  final user = args[0];
  final pass = args[1];

  final clock = SyncedServerClock();
  final transport = PortalTransport(baseUri: Uri.parse(_base), clock: clock);

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
    final session = Session(
      account: user,
      cookies: transport.jars.jarFor(user).cookies,
      establishedAt: DateTime.now().toUtc(),
    );
    print('login OK\n');

    // The cancel's FIRST navigation: GET the current week, and — because the
    // target is not in it — POST the next-week navigation.
    print('--- navigation 1 (the page the cancel posts against) ---');
    final first = await transport.get(user, _reservation);
    _report('GET current', first.body);
    final week1 = await transport.post(user, _reservation, body: {
      '__VIEWSTATE': _input(first.body, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': _input(first.body, '__VIEWSTATEGENERATOR'),
      '__EVENTTARGET': r'ctl00$cphMain$imgbtnNextWeek',
      '__EVENTARGUMENT': '',
    });
    _report('POST next week', week1.body);

    // Now the navigation the READ-BACK does, with no save in between. This
    // is what a *second* navigation looks like on a session that has already
    // navigated once.
    print('\n--- navigation 2 (the read-back, with no save between) ---');
    final second = await transport.get(user, _reservation);
    _report('GET current', second.body);
    final week2 = await transport.post(user, _reservation, body: {
      '__VIEWSTATE': _input(second.body, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': _input(second.body, '__VIEWSTATEGENERATOR'),
      '__EVENTTARGET': r'ctl00$cphMain$imgbtnNextWeek',
      '__EVENTARGUMENT': '',
    });
    _report('POST next week', week2.body);

    print('\n--- and a third, to see whether the pointer keeps moving ---');
    final third = await transport.get(user, _reservation);
    _report('GET current', third.body);
    final week3 = await transport.post(user, _reservation, body: {
      '__VIEWSTATE': _input(third.body, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': _input(third.body, '__VIEWSTATEGENERATOR'),
      '__EVENTTARGET': r'ctl00$cphMain$imgbtnNextWeek',
      '__EVENTARGUMENT': '',
    });
    _report('POST next week', week3.body);
  } catch (e, st) {
    print('EXCEPTION: $e');
    print(st.toString().split('\n').take(8).join('\n'));
  } finally {
    transport.close();
  }
}

/// Reports which week a page belongs to, and whether the target is on it.
void _report(String label, String html) {
  final week = _byId(html, 'cphMain_lblWeekDate') ?? '(no week label)';
  var found = false;
  var checked = false;
  var amount = 0;
  for (final slot in CullinanParser.reservationSlots) {
    final grid = switch (slot) {
      MealSlot.breakfast => 'grdReservationBreakfast',
      MealSlot.lunch => 'grdReservationLunch',
      MealSlot.dinner => 'grdReservationDinner',
    };
    for (final row in tableRows(html, grid)) {
      if (row.cells.length < 7) continue;
      final date = parseJalaliDate(row.cell(1));
      if (date == null) continue;
      if (date.year != _target.year ||
          date.month != _target.month ||
          date.day != _target.day) {
        continue;
      }
      found = true;
      final checkbox = inputBySuffix(row.raw, 'chkReserve');
      checked = checkbox?.checked ?? false;
      amount = _amount(row.cell(6));
      final status = rowStatus(row.raw);
      print('   target row: checked=$checked amount=$amount '
          'held=${status.held} locked=${status.locked}');
    }
  }
  print('$label  week="$week"  targetRowPresent=$found');
}

int _amount(String cell) {
  final digits = RegExp(r'\d[\d,٬]*').firstMatch(cell)?.group(0) ?? '';
  return int.tryParse(digits.replaceAll(RegExp(r'[^\d]'), '')) ?? 0;
}

String? _byId(String html, String id) {
  final m = RegExp('id="[^"]*' + RegExp.escape(id) + r'"[^>]*>(.*?)<',
          dotAll: true)
      .firstMatch(html);
  final t = m?.group(1)?.replaceAll(RegExp(r'\s+'), ' ').trim();
  return (t == null || t.isEmpty) ? null : t;
}

String _input(String html, String id) {
  final m = RegExp('id="' + RegExp.escape(id) + r'"[^>]*value="([^"]*)"')
      .firstMatch(html);
  return m?.group(1) ?? '';
}
