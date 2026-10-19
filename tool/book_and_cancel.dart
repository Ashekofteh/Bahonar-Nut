/// One booking-and-cancel cycle, on next week's cheapest meal.
///
/// WHAT THIS DOES, exactly once:
///   1. Books the cheapest breakfast in the published next week (1405/08/02+).
///   2. Verifies it is held AND that no other reservation was disturbed.
///   3. Cancels it by unchecking the row and saving again.
///   4. Verifies the cancel AND that the credit came back.
///
/// ## Why the whole form is submitted, not just one row
///
/// The reservation page holds THREE grids (breakfast, lunch, dinner) of seven
/// rows each. A browser submits every control in the form. An ASP.NET
/// checkbox that is *absent* from the POST reads as **unchecked**.
///
/// So posting only the target row would present every other CHECKED row as
/// unchecked — and the server would cancel the account's other reservations.
/// The safe form of the post is therefore the COMPLETE current form state
/// (every row's checkbox state and every row's dropdown values) with exactly
/// one field changed. That is what a human does in a browser, so it is what
/// this does.
///
/// The verify step checks the other reservations explicitly, so a mistake here
/// cannot pass unnoticed.
///
/// Usage: `dart run tool/book_and_cancel.dart <studentId> <password>`
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

/// One grid row, with every control it contributes to the form.
class GridRow {
  GridRow({
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
    required this.foodOptions,
    required this.hallOptions,
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
  final List<MapEntry<String, String>> foodOptions;
  final List<MapEntry<String, String>> hallOptions;

  @override
  String toString() =>
      '$date checked=$checked disabled=$disabled food=$foodValue';
}

/// One grid, with its rows.
class Grid {
  Grid(this.id, this.saveButton, this.rows);
  final String id;
  final String saveButton;
  final List<GridRow> rows;

  GridRow? rowFor(String date) {
    for (final r in rows) {
      if (r.date == date) return r;
    }
    return null;
  }
}

List<Grid> parseGrids(String html) {
  final grids = <Grid>[];
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
    grids.add(Grid(entry.$1, entry.$2, _rows(table.group(1)!)));
  }
  return grids;
}

List<GridRow> _rows(String body) {
  final out = <GridRow>[];
  for (final m in RegExp(r'<tr[^>]*>(.*?)</tr>', dotAll: true)
      .allMatches(body)) {
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
    final cbTag = cb?.group(0) ?? '';

    final self = _select(raw, 'drpSelf');
    final food = _select(raw, 'drpFood');
    final count = _select(raw, 'drpFoodCount');

    out.add(GridRow(
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
      foodOptions: food?.options ?? const [],
      hallOptions: self?.options ?? const [],
    ));
  }
  return out;
}

class _Select {
  _Select(this.name, this.value, this.options);
  final String name;
  final String value;
  final List<MapEntry<String, String>> options;
}

_Select? _select(String raw, String suffix) {
  final m = RegExp('<select[^>]*name="([^"]*' + RegExp.escape(suffix) +
          r')"[^>]*>(.*?)</select>',
          dotAll: true)
      .firstMatch(raw);
  if (m == null) return null;

  final options = <MapEntry<String, String>>[];
  String? selected;
  for (final o in RegExp(r'<option([^>]*)>(.*?)</option>', dotAll: true)
      .allMatches(m.group(2)!)) {
    final attrs = o.group(1)!;
    final value = _attr(attrs, 'value');
    final text = _text(o.group(2)!);
    // An option with no value attribute falls back to its text.
    final optionValue = value.isEmpty ? text : value;
    options.add(MapEntry(optionValue, text));
    if (selected == null && attrs.contains('selected')) {
      selected = optionValue;
    }
  }
  return _Select(m.group(1)!, selected ?? '', options);
}

/// Builds the COMPLETE form state, with [override] applied to one row.
///
/// Every row of every grid contributes its dropdown values, and its checkbox
/// only when it is checked (or when the override turns it on). This is exactly
/// what a browser posts.
///
/// The form-level hidden fields MUST be included too. `__VIEWSTATE` carries the
/// server's grid state; a post without it is processed against no state at all
/// and silently does nothing. (Observed 2026-10-19: a booking post missing
/// `__VIEWSTATE` returned 200, changed no reservation, and moved no money — no
/// error of any kind.)
Map<String, String> buildFormState(
  String html,
  List<Grid> grids, {
  String? uncheckDate,
  String? checkDate,
}) {
  final body = <String, String>{
    // Form-level state. `__VIEWSTATE` is the big one; the others are cheap to
    // include and the server expects them.
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

      final isChecked = row.checked;
      final shouldBeChecked = isChecked ||
          (checkDate != null && row.date == checkDate && !row.disabled);
      final shouldBeUnchecked = uncheckDate != null && row.date == uncheckDate;

      if (shouldBeChecked && !shouldBeUnchecked && row.checkboxName.isNotEmpty) {
        body[row.checkboxName] = 'on';
      }
    }
  }
  return body;
}

/// The reservations the account holds, as (slot, date) pairs.
Set<String> heldKeys(String html) {
  final held = <String>{};
  for (final grid in parseGrids(html)) {
    for (final row in grid.rows) {
      if (row.checked) held.add('${grid.id}|${row.date}');
    }
  }
  return held;
}

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run tool/book_and_cancel.dart <studentId> <password>');
    exitCode = 2;
    return;
  }
  final username = args[0];
  final password = args[1];

  captureDir = Directory('captures')..createSync(recursive: true);
  print('=== BOOK AND CANCEL ${DateTime.now().toIso8601String()} ===');

  final transport = PortalTransport(baseUri: Uri.parse(_base));

  try {
    // ------------------------------------------------------------- LOGIN
    final page = await transport.get(username, '/');
    final captcha =
        await transport.getBytes(username, '/UserControls/Captcha.ashx');
    final solution = CaptchaSolver().solve(captcha);
    print('captcha solved: ${solution.text}');
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
    print('login OK; credit BEFORE: $creditBefore');
    final heldBefore = heldKeys(login.body);
    print('held BEFORE: ${heldBefore.toList()..sort()}');

    // ------------------------------------------- NAVIGATE TO NEXT WEEK
    // One hop only: the current week is 1405/07/25..08/01, so ONE "next week"
    // click gives 1405/08/02..08/08, which is the published, bookable week. A
    // second hop lands on 1405/08/09, whose menu is not published yet (every row
    // renders '-'), so hopping twice would overshoot the target.
    final currentWeekHtml = login.body;
    var html = await _nextWeek(transport, username, currentWeekHtml);
    print('week: ${_textById(html, 'cphMain_lblWeekDate')}');
    save('50_next_week.html', html);

    // ---------------------------------------------- PICK THE TARGET
    final grids = parseGrids(html);
    final breakfast = grids.firstWhere((g) => g.id == 'grdReservationBreakfast');

    GridRow? target;
    MapEntry<String, String>? targetOption;
    var cheapest = 1 << 30;

    for (final row in breakfast.rows) {
      if (row.disabled) continue;
      for (final option in row.foodOptions) {
        final price = _price(option.value);
        if (price == null) continue;
        if (price < cheapest) {
          cheapest = price;
          target = row;
          targetOption = option;
        }
      }
    }

    if (target == null || targetOption == null) {
      print('!! no editable breakfast in next week');
      return;
    }
    print('\nTARGET: ${target.date}  ${targetOption.value}  '
        '($cheapest Rial)');

    // Hall preference: Central (1) first, Engineering (2) fallback.
    String hall = '1';
    if (!target.hallOptions.any((h) => h.key == '1') &&
        target.hallOptions.any((h) => h.key == '2')) {
      hall = '2';
    }
    print('hall: $hall '
        '(${target.hallOptions.where((h) => h.key == hall).map((h) => h.value).firstOrNull})');

    // ============================================================ BOOK
    print('\n--- STEP 1: BOOK ---');
    final bookBody = buildFormState(html, grids, checkDate: target.date)
      ..[target.selfName] = hall
      ..[target.foodName] = targetOption.key
      ..[target.countName] = '1'
      ..[breakfast.saveButton] = 'ذخیره صبحانه';

    print('POST fields: ${bookBody.length} '
        '(full form state + one checkbox added)');
    print('viewstate in body: ${(bookBody['__VIEWSTATE'] ?? '').length} chars');
    save('51_book_body.txt', _summarise(bookBody));

    final booked = await transport.post(username, '/Reservation/Reservation.aspx',
        body: bookBody);
    print('-> status ${booked.statusCode}');
    save('52_book_response.html', booked.body);

    // The response re-renders the server's DEFAULT week, not the week we
    // posted against, so it cannot be used to check the result. Re-read the
    // next week instead.
    final afterBookHtml = await _nextWeek(transport, username, booked.body);
    save('52b_after_book_next_week.html', afterBookHtml);

    final creditAfterBook = _credit(afterBookHtml);
    print('credit AFTER book: $creditAfterBook');
    if (creditBefore != null) {
      print('expected: ${creditBefore - cheapest}');
    }

    // Two different weeks, two different questions:
    //   * did the TARGET get booked? -> read the NEXT week (it lives there)
    //   * were the account's other reservations disturbed? -> read the CURRENT
    //     week, the same week `heldBefore` came from. Comparing a next-week
    //     read against a current-week baseline would report every existing
    //     reservation as lost.
    final heldAfterBook = heldKeys(afterBookHtml);
    final currentAfterBookResponse =
        await transport.get(username, '/Reservation/Reservation.aspx');
    final currentAfterBookHtml = currentAfterBookResponse.body;
    final heldCurrentAfterBook = heldKeys(currentAfterBookHtml);

    print('held in NEXT week after book: ${heldAfterBook.toList()..sort()}');
    print('held in CURRENT week after book: ${heldCurrentAfterBook.toList()..sort()}');

    final nowHeld = heldAfterBook.contains('grdReservationBreakfast|${target.date}');
    final collateral = heldBefore.difference(heldCurrentAfterBook);
    print('\nBOOK CHECK: target held = $nowHeld');
    print('COLLATERAL CHECK: current-week reservations lost = '
        '${collateral.isEmpty ? "NONE" : collateral.toList()}');

    if (!nowHeld) {
      print('\n!! booking did not take effect; NOT attempting a cancel');
      print('   a cancel of a meal that was never booked could cancel something else');
      return;
    }
    if (collateral.isNotEmpty) {
      print('\n!! OTHER RESERVATIONS WERE DISTURBED: $collateral');
      print('   stopping before the cancel so the damage is not compounded');
      return;
    }

    // ========================================================== CANCEL
    print('\n--- STEP 2: CANCEL (uncheck the row, save again) ---');
    // The form state comes from the re-read NEXT-WEEK page, so it reflects the
    // server's post-booking state for the week being changed.
    final gridsAfter = parseGrids(afterBookHtml);
    final cancelBody =
        buildFormState(afterBookHtml, gridsAfter, uncheckDate: target.date)
      ..[breakfast.saveButton] = 'ذخیره صبحانه';

    print('POST fields: ${cancelBody.length} '
        '(full form state, one checkbox removed)');
    save('53_cancel_body.txt', _summarise(cancelBody));

    final cancelled = await transport.post(
        username, '/Reservation/Reservation.aspx',
        body: cancelBody);
    print('-> status ${cancelled.statusCode}');
    save('54_cancel_response.html', cancelled.body);

    final afterCancelHtml = await _nextWeek(transport, username, cancelled.body);
    final creditAfterCancel = _credit(afterCancelHtml);
    print('credit AFTER cancel: $creditAfterCancel');
    print('expected: $creditBefore (the original balance)');

    final heldAfterCancel = heldKeys(afterCancelHtml);
    final currentAfterCancelResponse =
        await transport.get(username, '/Reservation/Reservation.aspx');
    final currentAfterCancelHtml = currentAfterCancelResponse.body;
    final heldCurrentAfterCancel = heldKeys(currentAfterCancelHtml);

    final stillHeld = heldAfterCancel.contains(
        'grdReservationBreakfast|${target.date}');
    final collateral2 = heldBefore.difference(heldCurrentAfterCancel);

    print('\nCANCEL CHECK: target still held = $stillHeld '
        '(expected false)');
    print('COLLATERAL CHECK: current-week reservations lost = '
        '${collateral2.isEmpty ? "NONE" : collateral2.toList()}');

    // ------------------------------------------- FINAL CONFIRMATION
    print('\n--- STEP 3: INDEPENDENT RE-READ (current week, fresh GET) ---');
    final confirm = await transport.get(username, '/Reservation/Reservation.aspx');
    final heldFinal = heldKeys(confirm.body);
    print('held NOW: ${heldFinal.toList()..sort()}');
    print('credit NOW: ${_credit(confirm.body)}');
    print('target still held = ${heldFinal.contains('grdReservationBreakfast|${target.date}')}');
    print('everything the account held BEFORE is still held = '
        '${heldBefore.difference(heldFinal).isEmpty}');
  } catch (e, st) {
    print('EXCEPTION: $e');
    print(st.toString().split('\n').take(8).join('\n'));
  } finally {
    transport.close();
  }
}

String _summarise(Map<String, String> body) =>
    body.entries.map((e) => '${e.key}=${e.value}').join('\n');

/// Returns the NEXT week's reservation page, given any reservation page.
///
/// The page's week is server state, not a URL parameter, so it is reached by
/// posting the `imgbtnNextWeek` event against the given page's viewstate.
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

int? _price(String text) {
  final buffer = StringBuffer();
  for (final rune in text.runes) {
    if (rune >= 0x06F0 && rune <= 0x06F9) {
      buffer.writeCharCode(rune - 0x06F0 + 0x30);
    } else if (rune >= 0x30 && rune <= 0x39) {
      buffer.writeCharCode(rune);
    }
  }
  final digits = buffer.toString();
  return digits.isEmpty ? null : int.tryParse(digits);
}

int? _credit(String html) {
  final label = _label(html, 'lblCredit');
  if (label == null) return null;
  return _price(label);
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
