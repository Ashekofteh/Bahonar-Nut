/// A live reproduction of the app's cancel, with every step printed.
///
/// The app's cancel reported **success** while the portal still held the meal
/// — and the ledger shows no cancel entry at all, so the post never took
/// effect. The adapter decides success by reading the portal back, so the
/// read-back saw a page on which the target row was not present.
///
/// The one thing the app does that the working tool did not: it reads the
/// reservations **first** (`fetchReservations` navigates to the next week),
/// and only then cancels. So this runs that same order, and prints the week
/// label of every page, so a pointer that moves is visible.
///
/// It performs the real cancel, and re-books the meal afterwards if the
/// cancel landed — so the account ends as it started.
///
/// Usage: `dart run tool/cancel_repro.dart <studentId> <password>`
library;

// One-shot live probe tool: stdout printing is the entire point.
// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/adapter/cullinan_client.dart';
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
    print('usage: dart run tool/cancel_repro.dart <studentId> <password>');
    return;
  }
  final user = args[0];
  final pass = args[1];

  final clock = SyncedServerClock();
  final transport = PortalTransport(baseUri: Uri.parse(_base), clock: clock);
  final client = CullinanPortalClient(transport: transport);

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
    print('login OK');

    // ---- STEP 1: the app's own read, which navigates to the next week ----
    print('\n=== STEP 1: fetchReservations (the app reads before it cancels)');
    final before = await client.fetchReservations(session);
    print('  reservations read: ${before.length}');
    for (final r in before) {
      if (_isTarget(r.date)) {
        print('  target present in the read: ${r.slot.name} ${r.option.name}');
      }
    }
    final balance0 = await client.fetchBalance(session);
    print('  credit before: ${balance0.amountRial}');

    // ---- STEP 2: the cancel's own navigation -----------------------------
    print('\n=== STEP 2: the cancel\'s navigation');
    final current = await transport.get(user, _reservation);
    _report('GET current', current.body);
    final covers = _weekCovers(current.body, _target);
    print('  current week covers the target: $covers');
    final cancelPage = covers
        ? current
        : await transport.post(user, _reservation, body: {
            '__VIEWSTATE': _input(current.body, '__VIEWSTATE'),
            '__VIEWSTATEGENERATOR':
                _input(current.body, '__VIEWSTATEGENERATOR'),
            '__EVENTTARGET': r'ctl00$cphMain$imgbtnNextWeek',
            '__EVENTARGUMENT': '',
          });
    _report('cancel page', cancelPage.body);

    // ---- STEP 3: the body -------------------------------------------------
    final body = _cancelBody(cancelPage.body);
    print('\n=== STEP 3: the body');
    print('  keys: ${body.length}');
    print('  save button present: '
        '${body.keys.any((k) => k.contains('btnSaveBreakfast'))}');
    print('  target checkbox present: '
        '${body.keys.any((k) => k.contains('chkReserve') && k.contains('ctl03'))}');
    print('  checked rows re-posted: '
        '${body.keys.where((k) => k.endsWith('chkReserve')).length}');

    // ---- STEP 4: the post -------------------------------------------------
    print('\n=== STEP 4: POST the save');
    final posted = await transport.post(user, _reservation, body: body);
    _report('post response', posted.body);

    // ---- STEP 5: the read-back -------------------------------------------
    print('\n=== STEP 5: the read-back');
    final back = await transport.get(user, _reservation);
    _report('GET current', back.body);
    final backCovers = _weekCovers(back.body, _target);
    print('  current week covers the target: $backCovers');
    final confirmation = backCovers
        ? back
        : await transport.post(user, _reservation, body: {
            '__VIEWSTATE': _input(back.body, '__VIEWSTATE'),
            '__VIEWSTATEGENERATOR': _input(back.body, '__VIEWSTATEGENERATOR'),
            '__EVENTTARGET': r'ctl00$cphMain$imgbtnNextWeek',
            '__EVENTARGUMENT': '',
          });
    _report('confirmation', confirmation.body);
    print('  => the adapter would read this as '
        '"still held: ${_stillHeld(confirmation.body)}"');

    // ---- STEP 6: what the portal actually holds --------------------------
    final after = await client.fetchReservations(session);
    final balance1 = await client.fetchBalance(session);
    print('\n=== STEP 6: the portal\'s own state');
    print('  reservations now: ${after.length}');
    print('  target still held: '
        '${after.any((r) => _isTarget(r.date) && r.slot == _targetSlot)}');
    print('  credit now: ${balance1.amountRial}');

    // ---- STEP 7: restore --------------------------------------------------
    if (!after.any((r) => _isTarget(r.date) && r.slot == _targetSlot)) {
      print('\n=== STEP 7: the cancel landed — re-booking the meal');
      final target = after.firstWhere(
        (r) => _isTarget(r.date) && r.slot == _targetSlot,
        orElse: () => before.firstWhere((r) => _isTarget(r.date)),
      );
      final offering = MealOffering(
        date: target.date,
        slot: target.slot,
        hall: target.hall,
        option: target.option,
        reservable: true,
      );
      try {
        await client.reserve(session, offering);
        print('  re-booked: ${_d(target.date)} ${target.slot.name}');
      } catch (e) {
        print('  !! re-book threw: $e');
      }
      final balance2 = await client.fetchBalance(session);
      print('  credit now: ${balance2.amountRial}');
    }
  } catch (e, st) {
    print('EXCEPTION: $e');
    print(st.toString().split('\n').take(8).join('\n'));
  } finally {
    transport.close();
  }
}

bool _isTarget(DateTime d) =>
    d.year == _target.year && d.month == _target.month && d.day == _target.day;

/// The adapter's read-back rule.
bool _stillHeld(String html) {
  for (final row in tableRows(html, _gridForSlot(_targetSlot))) {
    if (row.cells.length < 7) continue;
    final date = parseJalaliDate(row.cell(1));
    if (date == null || !_isTarget(date)) continue;
    final checkbox = inputBySuffix(row.raw, 'chkReserve');
    if (checkbox == null || !checkbox.checked) return false;
    final status = rowStatus(row.raw);
    if (!status.held) return false;
    return (parseRial(row.cell(6)) ?? 0) > 0;
  }
  return false;
}

bool _weekCovers(String html, DateTime date) {
  for (final slot in CullinanParser.reservationSlots) {
    for (final row in tableRows(html, _gridForSlot(slot))) {
      final rowDate = parseJalaliDate(row.cell(1));
      if (rowDate == null) continue;
      if (rowDate.year == date.year &&
          rowDate.month == date.month &&
          rowDate.day == date.day) {
        return true;
      }
    }
  }
  return false;
}

/// The adapter's cancel body, copied.
Map<String, String> _cancelBody(String html) {
  final body = <String, String>{
    '__VIEWSTATE': _input(html, '__VIEWSTATE'),
    '__VIEWSTATEGENERATOR': _input(html, '__VIEWSTATEGENERATOR'),
    '__EVENTTARGET': '',
    '__EVENTARGUMENT': '',
  };
  for (final slot in CullinanParser.reservationSlots) {
    for (final row in tableRows(html, _gridForSlot(slot))) {
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
      final isTarget = slot == _targetSlot && _isTarget(date);
      if (!isTarget && checkbox.checked && _genuinelyHeld(row)) {
        body[checkbox.name] = 'on';
      }
    }
  }
  body[r'ctl00$cphMain$btnSaveBreakfast'] = 'ذخیره';
  return body;
}

bool _genuinelyHeld(ParsedRow row) {
  final status = rowStatus(row.raw);
  if (!status.held) return false;
  return (parseRial(row.cell(6)) ?? 0) > 0;
}

void _report(String label, String html) {
  final week = _byId(html, 'cphMain_lblWeekDate') ?? '(no week label)';
  var present = false;
  var checked = false;
  var amount = 0;
  var held = false;
  for (final row in tableRows(html, _gridForSlot(_targetSlot))) {
    if (row.cells.length < 7) continue;
    final date = parseJalaliDate(row.cell(1));
    if (date == null || !_isTarget(date)) continue;
    present = true;
    final checkbox = inputBySuffix(row.raw, 'chkReserve');
    checked = checkbox?.checked ?? false;
    amount = parseRial(row.cell(6)) ?? 0;
    held = rowStatus(row.raw).held;
  }
  print('  $label: week="$week" targetPresent=$present '
      'checked=$checked amount=$amount held=$held');
}

String _gridForSlot(MealSlot slot) => switch (slot) {
      MealSlot.breakfast => 'grdReservationBreakfast',
      MealSlot.lunch => 'grdReservationLunch',
      MealSlot.dinner => 'grdReservationDinner',
    };

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
