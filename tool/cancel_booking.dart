/// Cancel the booking just made, and verify.
///
/// The booking (1405/08/03 breakfast, 150,000 Rial) is confirmed: the credit
/// went 500,000 -> 350,000 and exactly one reservation is held.
///
/// ## Why the cancel is safe
///
/// The grid control names (`$ctl02$chkReserve` .. `$ctl08$chkReserve`) are
/// IDENTICAL in every week - the index is the ROW position, not the date. So
/// which week's rows a post affects is decided by the `__VIEWSTATE`, which
/// encodes the week the page was showing.
///
/// Posting the NEXT week's viewstate therefore operates on the next week's
/// rows and leaves the current week untouched. Empirically confirmed by the
/// booking itself: the current week's four reservations (breakfast 07/27,
/// breakfast 07/29, dinner 07/28, lunch 07/30) were all still held afterwards.
///
/// ## The cancel
///
/// Uncheck the target row's checkbox and post with that grid's save button.
/// The server sees the row as unchecked and releases it.
///
/// The form state is built from a FRESH read of the target week, not from the
/// booking response: the booking response renders unchecked lunch/dinner rows
/// as `checked` (an echo of what was posted), and re-posting that would
/// re-check them.
///
/// Usage: `dart run tool/cancel_booking.dart <studentId> <password> [jalaliDate]
// One-shot live action tool: stdout printing is the entire point.
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

class RowView {
  RowView({
    required this.date,
    required this.checkboxName,
    required this.checked,
    required this.disabled,
    required this.selfName,
    required this.selfValue,
    required this.foodName,
    required this.foodValue,
    required this.countName,
    required this.countValue,
    required this.amount,
    required this.reservedIcon,
  });

  final String date;
  final String checkboxName;
  final bool checked;
  final bool disabled;
  final String selfName;
  final String selfValue;
  final String foodName;
  final String foodValue;
  final String countName;
  final String countValue;

  /// The مبلغ خرید cell. Non-zero for a meal that was actually charged.
  final int amount;

  /// The portal's green "رزرو شده" marker.
  final bool reservedIcon;

  /// A meal is genuinely held only if it was charged and carries the marker.
  ///
  /// `checked` alone is NOT sufficient: an unchecked row that was posted as
  /// checked comes back rendered as `checked` with amount 0 and no icon.
  bool get isHeld => reservedIcon && amount > 0;

  @override
  String toString() => '$date checked=$checked held=$isHeld';
}

class GridView {
  GridView(this.id, this.saveButton, this.rows);
  final String id;
  final String saveButton;
  final List<RowView> rows;

  RowView? rowFor(String date) {
    for (final r in rows) {
      if (r.date == date) return r;
    }
    return null;
  }
}

List<GridView> parseGrids(String html) {
  final grids = <GridView>[];
  for (final entry in <(String, String)>[
    ('grdReservationBreakfast', 'ctl00\$cphMain\$btnSaveBreakfast'),
    ('grdReservationLunch', 'ctl00\$cphMain\$btnSaveLunch'),
    ('grdReservationDinner', 'ctl00\$cphMain\$btnSaveDinner'),
  ]) {
    final table = RegExp('<table[^>]*id="[^"]*' + RegExp.escape(entry.$1) +
            r'"[^>]*>(.*?)</table>',
            dotAll: true)
        .firstMatch(html);
    if (table == null) continue;
    grids.add(GridView(entry.$1, entry.$2, _rows(table.group(1)!)));
  }
  return grids;
}

List<RowView> _rows(String body) {
  final out = <RowView>[];
  for (final m in RegExp(r'<tr[^>]*>(.*?)</tr>', dotAll: true)
      .allMatches(body)) {
    final raw = m.group(1)!;
    final cells = RegExp(r'<td[^>]*>(.*?)</td>', dotAll: true)
        .allMatches(raw)
        .map((c) => c.group(1)!)
        .toList();
    if (cells.length < 7) continue;

    final label = _text(cells[1]);
    final date = RegExp(r'\d{4}/\d{2}/\d{2}').firstMatch(label)?.group(0) ?? '';
    if (date.isEmpty) continue;

    final cb = RegExp(r'<input[^>]*type="checkbox"[^>]*>', dotAll: true)
        .firstMatch(raw);
    final cbTag = cb?.group(0) ?? '';
    final self = _select(raw, 'drpSelf');
    final food = _select(raw, 'drpFood');
    final count = _select(raw, 'drpFoodCount');
    final amount = int.tryParse(_text(cells[6]).replaceAll(RegExp(r'\D'), '')) ?? 0;

    out.add(RowView(
      date: date,
      checkboxName: _attr(cbTag, 'name'),
      checked: cbTag.contains('checked'),
      disabled: cbTag.contains('disabled'),
      selfName: self?.name ?? '',
      selfValue: self?.value ?? '',
      foodName: food?.name ?? '',
      foodValue: food?.value ?? '',
      countName: count?.name ?? '',
      countValue: count?.value ?? '1',
      amount: amount,
      reservedIcon: raw.contains('imgStaus'),
    ));
  }
  return out;
}

class _Sel {
  _Sel(this.name, this.value);
  final String name;
  final String value;
}

_Sel? _select(String raw, String suffix) {
  final m = RegExp('<select[^>]*name="([^"]*' + RegExp.escape(suffix) +
          r')"[^>]*>(.*?)</select>',
          dotAll: true)
      .firstMatch(raw);
  if (m == null) return null;

  String? selected;
  for (final o in RegExp(r'<option([^>]*)>(.*?)</option>', dotAll: true)
      .allMatches(m.group(2)!)) {
    final attrs = o.group(1)!;
    if (selected == null && attrs.contains('selected')) {
      final v = _attr(attrs, 'value');
      selected = v.isEmpty ? _text(o.group(2)!) : v;
    }
  }
  return _Sel(m.group(1)!, selected ?? '');
}

/// The form state for the page, with one row's checkbox removed.
Map<String, String> buildFormState(String html, List<GridView> grids,
    {String? uncheckDate}) {
  final body = <String, String>{
    '__VIEWSTATE': _input(html, '__VIEWSTATE'),
    '__VIEWSTATEGENERATOR': _input(html, '__VIEWSTATEGENERATOR'),
    '__VIEWSTATEENCRYPTED': _input(html, '__VIEWSTATEENCRYPTED'),
    '__EVENTTARGET': '',
    '__EVENTARGUMENT': '',
    '__LASTFOCUS': '',
  };

  for (final grid in grids) {
    for (final row in grid.rows) {
      if (row.selfName.isNotEmpty) body[row.selfName] = row.selfValue;
      if (row.foodName.isNotEmpty) body[row.foodName] = row.foodValue;
      if (row.countName.isNotEmpty) body[row.countName] = row.countValue;

      // Only a genuinely held row keeps its checkbox. A row that merely echoes
      // `checked` (because it was posted as checked but never charged) must NOT
      // be re-checked, or the cancel would book it instead.
      final keep = row.isHeld && row.date != uncheckDate;
      if (keep && row.checkboxName.isNotEmpty) {
        body[row.checkboxName] = 'on';
      }
    }
  }
  return body;
}

/// The meals genuinely held, as "grid|date" keys.
Set<String> heldKeys(String html) {
  final held = <String>{};
  for (final grid in parseGrids(html)) {
    for (final row in grid.rows) {
      if (row.isHeld) held.add('${grid.id}|${row.date}');
    }
  }
  return held;
}

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run tool/cancel_booking.dart <studentId> <password> '
        '[jalaliDate]');
    exitCode = 2;
    return;
  }
  final username = args[0];
  final password = args[1];
  final targetDate = args.length > 2 ? args[2] : '1405/08/03';

  captureDir = Directory('captures')..createSync(recursive: true);
  print('=== CANCEL ${DateTime.now().toIso8601String()} ===');
  print('target: $targetDate');

  final transport = PortalTransport(baseUri: Uri.parse(_base));

  try {
    // LOGIN
    final page = await transport.get(username, '/');
    final captcha =
        await transport.getBytes(username, '/UserControls/Captcha.ashx');
    final solution = CaptchaSolver().solve(captcha);
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
    final creditBefore = _credit(login.body);
    print('credit BEFORE cancel: $creditBefore');

    // Current week baseline.
    final currentBefore = login.body;
    final heldCurrentBefore = heldKeys(currentBefore);
    print('held in CURRENT week before: ${heldCurrentBefore.toList()..sort()}');

    // The week holding the booking: 1405/08/02..08/08, one hop from current.
    final targetWeek = await _nextWeek(transport, username, currentBefore);
    print('target week: ${_textById(targetWeek, 'cphMain_lblWeekDate')}');
    save('60_week_with_booking.html', targetWeek);

    final grids = parseGrids(targetWeek);
    final breakfast =
        grids.firstWhere((g) => g.id == 'grdReservationBreakfast');
    final row = breakfast.rowFor(targetDate);

    if (row == null) {
      print('!! no row for $targetDate in the breakfast grid');
      return;
    }
    print('row: $row  (held=${row.isHeld})');

    if (!row.isHeld) {
      print('!! the target row is not actually held - refusing to cancel');
      return;
    }

    // ---------------------------------------------- CANCEL
    print('\n--- CANCEL ---');
    final cancelBody = buildFormState(targetWeek, grids, uncheckDate: targetDate)
      ..[breakfast.saveButton] = 'ذخیره صبحانه';

    print('POST fields: ${cancelBody.length}');
    print('checkboxes sent as on: '
        '${cancelBody.keys.where((k) => k.contains('chkReserve')).length}');
    save('61_cancel_body.txt',
        cancelBody.entries.map((e) => '${e.key}=${e.value}').join('\n'));

    final cancelled = await transport.post(
        username, '/Reservation/Reservation.aspx',
        body: cancelBody);
    print('-> status ${cancelled.statusCode}');
    save('62_cancel_response.html', cancelled.body);

    // Verify in the target week.
    final afterWeek = await _nextWeek(transport, username, cancelled.body);
    final heldAfterWeek = heldKeys(afterWeek);
    final creditAfter = _credit(afterWeek);
    print('\ncredit AFTER cancel: $creditAfter  (expected $creditBefore)');
    print('held in target week after: ${heldAfterWeek.toList()..sort()}');
    final stillHeld =
        heldAfterWeek.contains('grdReservationBreakfast|$targetDate');
    print('TARGET STILL HELD: $stillHeld (expected false)');

    // Verify the current week is untouched.
    final currentAfter =
        await transport.get(username, '/Reservation/Reservation.aspx');
    final heldCurrentAfter = heldKeys(currentAfter.body);
    final collateral = heldCurrentBefore.difference(heldCurrentAfter);
    print('\nheld in CURRENT week after: ${heldCurrentAfter.toList()..sort()}');
    print('COLLATERAL: current-week reservations lost = '
        '${collateral.isEmpty ? "NONE" : collateral.toList()}');
    print('credit NOW (fresh GET): ${_credit(currentAfter.body)}');
  } catch (e, st) {
    print('EXCEPTION: $e');
    print(st.toString().split('\n').take(8).join('\n'));
  } finally {
    transport.close();
  }
}

Future<String> _nextWeek(
  PortalTransport transport,
  String username,
  String fromHtml,
) async {
  final response = await transport.post(
    username, '/Reservation/Reservation.aspx',
    body: {
      '__VIEWSTATE': _input(fromHtml, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': _input(fromHtml, '__VIEWSTATEGENERATOR'),
      '__EVENTTARGET': 'ctl00\$cphMain\$imgbtnNextWeek',
      '__EVENTARGUMENT': '',
    },
  );
  return response.body;
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

int? _credit(String html) {
  final label = _label(html, 'lblCredit');
  if (label == null) return null;
  return int.tryParse(label.replaceAll(RegExp(r'\D'), ''));
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
