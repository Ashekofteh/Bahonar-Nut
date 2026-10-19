/// Read-only probe: how does one cancel a weekly reservation?
///
/// Before booking anything, find out whether a cancel affordance exists and
/// what it is called. The weekly reservation hub has no obvious cancel button
/// in the recon notes, and the cafeteria page has a `btnCancelHidden`. If the
/// only mechanism is "uncheck the box and save again", that is what we must
/// use — and it only works while the date is still editable.
///
/// Also reports the cheapest bookable meal for next week, so the eventual
/// booking costs as little as possible.
///
/// READ-ONLY. Books and cancels nothing.
///
/// Usage: `dart run tool/cancel_probe.dart <studentId> <password>`
// Read-only diagnostic probe: stdout printing is the entire point.
// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings

library;

import 'dart:io';

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/transport/http_transport.dart';

const _base = 'https://nut.uk.ac.ir/';

late Directory captureDir;

void save(String name, String content) {
  File('${captureDir.path}/$name').writeAsStringSync(content);
  print('   [capture] $name (${content.length} chars)');
}

/// Every control whose name, id or value looks cancellation-related.
List<String> cancelControls(String html) {
  final found = <String>[];
  for (final m in RegExp(r'<(input|button|a|select)[^>]*>', dotAll: true)
      .allMatches(html)) {
    final tag = m.group(0)!;
    final lower = tag.toLowerCase();
    final isCancel = lower.contains('cancel') ||
        lower.contains('delete') ||
        lower.contains('remove') ||
        // Persian: لغو (cancel), حذف (delete)
        tag.contains('لغو') ||
        tag.contains('حذف');
    if (!isCancel) continue;

    final name = _attr(tag, 'name');
    final id = _attr(tag, 'id');
    final value = _attr(tag, 'value');
    final type = _attr(tag, 'type');
    found.add('  <${m.group(1)}> type=$type name="$name" id="$id" value="$value"');
  }
  return found;
}

/// The controls on a grid row, and whether the row is editable.
class RowInfo {
  RowInfo(this.date, this.checked, this.disabled, this.cells, this.controls);
  final String date;
  final bool checked;
  final bool disabled;
  final String cells;
  final List<String> controls;
}

List<RowInfo> rows(String html, String gridId) {
  final table = RegExp('<table[^>]*id="[^"]*' + RegExp.escape(gridId) +
          r'"[^>]*>(.*?)</table>',
          dotAll: true)
      .firstMatch(html);
  if (table == null) return const [];

  final out = <RowInfo>[];
  for (final m in RegExp(r'<tr[^>]*>(.*?)</tr>', dotAll: true)
      .allMatches(table.group(1)!)) {
    final raw = m.group(1)!;
    final cells = RegExp(r'<td[^>]*>(.*?)</td>', dotAll: true)
        .allMatches(raw)
        .map((c) => c.group(1)!)
        .toList();
    if (cells.length < 4) continue;

    final label = _text(cells[1]);
    final date = RegExp(r'\d{4}/\d{2}/\d{2}').firstMatch(label)?.group(0) ?? '';
    if (date.isEmpty) continue;

    final cb = RegExp(r'<input[^>]*type="checkbox"[^>]*>', dotAll: true)
        .firstMatch(raw);
    final tag = cb?.group(0) ?? '';

    final controls = <String>[];
    for (final c in RegExp(r'<(input|select|button)[^>]*>', dotAll: true)
        .allMatches(raw)) {
      controls.add('      ${_attr(c.group(0)!, 'name')} '
          '(${_attr(c.group(0)!, 'type')})');
    }

    out.add(RowInfo(
      date,
      tag.contains('checked'),
      tag.contains('disabled'),
      _text(cells[3]),
      controls,
    ));
  }
  return out;
}

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run tool/cancel_probe.dart <studentId> <password>');
    exitCode = 2;
    return;
  }
  final username = args[0];
  final password = args[1];

  captureDir = Directory('captures')..createSync(recursive: true);
  print('=== CANCEL PROBE ${DateTime.now().toIso8601String()} ===');

  final transport = PortalTransport(baseUri: Uri.parse(_base));

  try {
    // LOGIN
    final page = await transport.get(username, '/');
    final captcha =
        await transport.getBytes(username, '/UserControls/Captcha.ashx');
    final solution = CaptchaSolver().solve(captcha);
    print('solved captcha: ${solution.text}');
    final login = await transport.post(username, '/', body: {
      '__VIEWSTATE': _input(page.body, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': _input(page.body, '__VIEWSTATEGENERATOR'),
      '__VIEWSTATEENCRYPTED': '',
      'txtUsername': username,
      'txtPassword': password,
      'txtCaptcha': solution.text!,
      'btnLogin': 'ورود سمت سرور ',
    });
    if (login.body.contains('txtUsernamePlain')) {
      print('!! LOGIN FAILED');
      return;
    }
    print('login OK; credit: ${_label(login.body, 'lblCredit')}');

    // ---------------------------------------------- RESERVATION HUB
    print('\n--- Reservation.aspx (current week) ---');
    final reservation =
        await transport.get(username, '/Reservation/Reservation.aspx');
    save('30_reservation_current.html', reservation.body);
    print('week: ${_textById(reservation.body, 'cphMain_lblWeekDate')}');

    final cancels = cancelControls(reservation.body);
    print('cancel-related controls on the reservation hub: '
        '${cancels.isEmpty ? "NONE" : ""}');
    for (final c in cancels) {
      print(c);
    }

    for (final grid in [
      'grdReservationBreakfast',
      'grdReservationLunch',
      'grdReservationDinner'
    ]) {
      print('\n  grid $grid:');
      for (final r in rows(reservation.body, grid)) {
        print('   ${r.date} checked=${r.checked} disabled=${r.disabled} '
            'food="${r.cells.substring(0, r.cells.length > 34 ? 34 : r.cells.length)}"');
        for (final c in r.controls) {
          print('     $c');
        }
      }
    }

    // ------------------------------------------------- CAFETERIA PAGE
    print('\n--- CafeteriaReservation.aspx ---');
    final cafeteria =
        await transport.get(username, '/Reservation/CafeteriaReservation.aspx');
    save('31_cafeteria.html', cafeteria.body);
    final cafCancels = cancelControls(cafeteria.body);
    print('cancel-related controls: ${cafCancels.isEmpty ? "NONE" : ""}');
    for (final c in cafCancels) {
      print(c);
    }
    print('week/day: ${_textById(cafeteria.body, 'cphMain_lblTodayDate')}');

    // ----------------------------------------------- NEXT WEEK PRICES
    print('\n--- Next week: which meal is cheapest to book? ---');
    var html = reservation.body;
    for (var hop = 0; hop < 1; hop++) {
      final response = await transport.post(
          username, '/Reservation/Reservation.aspx',
          body: {
            '__VIEWSTATE': _input(html, '__VIEWSTATE'),
            '__VIEWSTATEGENERATOR': _input(html, '__VIEWSTATEGENERATOR'),
            '__EVENTTARGET': 'ctl00\$cphMain\$imgbtnNextWeek',
            '__EVENTARGUMENT': '',
          });
      html = response.body;
    }
    save('32_next_week.html', html);
    print('week: ${_textById(html, 'cphMain_lblWeekDate')}');

    for (final entry in <(String, String)>[
      ('grdReservationBreakfast', 'breakfast'),
      ('grdReservationLunch', 'lunch'),
      ('grdReservationDinner', 'dinner'),
    ]) {
      for (final r in rows(html, entry.$1)) {
        if (r.disabled) continue;
        // Price is the 7th cell of the grid.
        final table = RegExp('<table[^>]*id="[^"]*' +
                RegExp.escape(entry.$1) +
                r'"[^>]*>(.*?)</table>',
            dotAll: true)
            .firstMatch(html);
        var price = '';
        for (final m in RegExp(r'<tr[^>]*>(.*?)</tr>', dotAll: true)
            .allMatches(table?.group(1) ?? '')) {
          final cells = RegExp(r'<td[^>]*>(.*?)</td>', dotAll: true)
              .allMatches(m.group(1)!)
              .map((c) => c.group(1)!)
              .toList();
          if (cells.length < 7) continue;
          final label = _text(cells[1]);
          if (!label.contains(r.date)) continue;
          price = _text(cells[6]);
        }
        print('   ${entry.$2.padRight(10)} ${r.date} price=$price  '
            'food="${r.cells.substring(0, r.cells.length > 30 ? 30 : r.cells.length)}"');
      }
    }

    // ------------------------------------------- FORGOT RECEIPT PAGE
    print('\n--- ForgotReceipt.aspx (penalty context) ---');
    final forgot =
        await transport.get(username, '/Reservation/ForgotReceipt.aspx');
    save('33_forgot_receipt.html', forgot.body);
    final forgotText = _text(forgot.body);
    // Pull the section that explains the allowance.
    final idx = forgotText.indexOf('مهلت');
    if (idx >= 0) {
      print('   ${forgotText.substring(idx > 200 ? idx - 200 : 0,
          (idx + 500).clamp(0, forgotText.length))}');
    } else {
      print('   (text snippet unavailable; see capture)');
    }
  } catch (e, st) {
    print('EXCEPTION: $e');
    print(st.toString().split('\n').take(8).join('\n'));
  } finally {
    transport.close();
  }
}

String _text(String html) => html
    .replaceAll(RegExp(r'<[^>]*>'), ' ')
    .replaceAll('&nbsp;', ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String _attr(String tag, String name) {
  final m = RegExp('${RegExp.escape(name)}\\s*=\\s*"([^"]*)"').firstMatch(tag);
  return m?.group(1) ?? '';
}

String _input(String html, String id) {
  final m = RegExp('id="' + RegExp.escape(id) + r'"[^>]*value="([^"]*)"')
      .firstMatch(html);
  return m?.group(1) ?? '';
}

String? _label(String html, String id) {
  final m = RegExp('<label[^>]*id="' + RegExp.escape(id) + r'"[^>]*>(.*?)</label>',
          dotAll: true)
      .firstMatch(html);
  final t = m?.group(1)?.replaceAll(RegExp(r'\s+'), ' ').trim();
  return (t == null || t.isEmpty) ? null : t;
}

String? _textById(String html, String id) {
  final m = RegExp('id="[^"]*' + RegExp.escape(id) + r'"[^>]*>(.*?)<', dotAll: true)
      .firstMatch(html);
  final t = m?.group(1)?.replaceAll(RegExp(r'\s+'), ' ').trim();
  return (t == null || t.isEmpty) ? null : t;
}
