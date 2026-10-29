/// A **dry run** of the adapter's cancel: it builds the exact form body the
/// adapter would post, and prints it — but posts **nothing**.
///
/// The app's cancel reported success while the portal still held the meal.
/// The adapter decides success by reading the portal back, so the read-back
/// must have said "gone". Either the read-back looked at the wrong page, or
/// it looked at the right page and did not recognise the row.
///
/// This prints the body the adapter builds, so the row it targets and the
/// rows it re-posts can be checked by eye against what the portal renders.
///
/// Usage: `dart run tool/cancel_dryrun.dart <studentId> <password>`
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

final _target = DateTime.utc(2026, 10, 25);
const _targetSlot = MealSlot.breakfast;

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run tool/cancel_dryrun.dart <studentId> <password>');
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

    // The page the cancel posts against: next week.
    final current = await transport.get(user, _reservation);
    final next = await transport.post(user, _reservation, body: {
      '__VIEWSTATE': _input(current.body, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': _input(current.body, '__VIEWSTATEGENERATOR'),
      '__EVENTTARGET': r'ctl00$cphMain$imgbtnNextWeek',
      '__EVENTARGUMENT': '',
    });
    final html = next.body;
    print('week = "${_byId(html, 'cphMain_lblWeekDate')}"');

    // --- What the page renders, row by row --------------------------------
    print('\n--- what the page renders ---');
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
        final checkbox = inputBySuffix(row.raw, 'chkReserve');
        final status = rowStatus(row.raw);
        final amount = _amount(row.cell(6));
        final isTarget = slot == _targetSlot &&
            date.year == _target.year &&
            date.month == _target.month &&
            date.day == _target.day;
        print('  ${slot.name.padRight(9)} ${_d(date)}  '
            'checked=${checkbox?.checked ?? false}  '
            'disabled=${checkbox?.disabled ?? false}  '
            'amount=$amount  held=${status.held}  locked=${status.locked}'
            '${isTarget ? '   <== TARGET' : ''}');
        if (checkbox != null) {
          print('        checkbox name = ${checkbox.name}');
        }
      }
    }

    // --- The body the adapter would build ---------------------------------
    final body = <String, String>{
      '__VIEWSTATE': _input(html, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': _input(html, '__VIEWSTATEGENERATOR'),
      '__EVENTTARGET': '',
      '__EVENTARGUMENT': '',
    };
    for (final slot in CullinanParser.reservationSlots) {
      final grid = switch (slot) {
        MealSlot.breakfast => 'grdReservationBreakfast',
        MealSlot.lunch => 'grdReservationLunch',
        MealSlot.dinner => 'grdReservationDinner',
      };
      for (final row in tableRows(html, grid)) {
        final date = parseJalaliDate(row.cell(1));
        if (date == null) continue;
        final checkbox = inputBySuffix(row.raw, 'chkReserve');
        final self = selectBySuffix(row.raw, 'drpSelf');
        final food = selectBySuffix(row.raw, 'drpFood');
        final count = selectBySuffix(row.raw, 'drpFoodCount');
        if (checkbox == null || self == null || food == null || count == null) {
          continue;
        }
        body[self.name] = self.selected?.value ?? '-1';
        body[food.name] = food.selected?.value ?? '-1';
        body[count.name] = count.selected?.value ?? '0';

        final isTarget = slot == _targetSlot &&
            date.year == _target.year &&
            date.month == _target.month &&
            date.day == _target.day;
        final genuinelyHeld = status_held(row);
        if (!isTarget && checkbox.checked && genuinelyHeld) {
          body[checkbox.name] = 'on';
        }
        if (isTarget) {
          print('\nTARGET row: checked=${checkbox.checked} '
              'genuinelyHeld=$genuinelyHeld');
          print('   -> the adapter OMITS ${checkbox.name} (that is the uncheck)');
        }
      }
    }
    body[_saveButton(_targetSlot)] = 'ذخیره';

    print('\n--- the body the adapter would post ---');
    final keys = body.keys.toList()..sort();
    for (final key in keys) {
      final value = body[key]!;
      if (key.startsWith('__')) {
        print('  $key = ${value.length} chars');
      } else {
        print('  $key = $value');
      }
    }
  } catch (e, st) {
    print('EXCEPTION: $e');
    print(st.toString().split('\n').take(8).join('\n'));
  } finally {
    transport.close();
  }
}

/// The adapter's own rule: a held row carries the green icon **and** a
/// non-zero amount.
bool status_held(ParsedRow row) {
  final status = rowStatus(row.raw);
  if (!status.held) return false;
  return (parseRial(row.cell(6)) ?? 0) > 0;
}

String _saveButton(MealSlot slot) => switch (slot) {
      MealSlot.breakfast => r'ctl00$cphMain$btnSaveBreakfast',
      MealSlot.lunch => r'ctl00$cphMain$btnSaveLunch',
      MealSlot.dinner => r'ctl00$cphMain$btnSaveDinner',
    };

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

String _d(DateTime date) => date.toIso8601String().substring(0, 10);

String _input(String html, String id) {
  final m = RegExp('id="' + RegExp.escape(id) + r'"[^>]*value="([^"]*)"')
      .firstMatch(html);
  return m?.group(1) ?? '';
}
