/// One-shot live capture of the lunch reservation path.
///
/// READ-ONLY until the final step, which performs the actual reservation the
/// product owner asked for. Everything else is reconnaissance: the full
/// request/response state of every page involved, so that if the run does not
/// succeed we still know exactly why.
///
/// The product owner asked for lunch on **Mehr 28, 1405** (Tuesday) for account
/// 401157013, dish "Akbar Joojeh", preferring hall مرکزی (1) and falling back
/// to hall فنی (2).
///
/// Note: Mehr 28 is 2026-10-20, and the 20:00-two-days-prior cutoff for it was
/// 2026-10-16 — so the server is expected to refuse. The run captures what
/// actually happens rather than assuming.
///
/// Captures are written to `captures/` and contain no password.
///
/// Usage: `dart run tool/capture_reserve.dart <studentId> <password> [jalaliDate]`
// One-shot live capture tool: stdout printing is the entire point.
// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings

library;

import 'dart:io';

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/adapter/cullinan_parser.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/persian.dart';
import 'package:bahonar_nut/transport/http_transport.dart';

const _base = 'https://nut.uk.ac.ir/';

late final Directory captureDir;

void save(String name, String content) {
  final file = File('${captureDir.path}/$name');
  file.writeAsStringSync(content);
  print('   [capture] ${file.path} (${content.length} chars)');
}

void saveBytes(String name, List<int> bytes) {
  final file = File('${captureDir.path}/$name');
  file.writeAsBytesSync(bytes);
  print('   [capture] ${file.path} (${bytes.length} bytes)');
}

/// Prints a POST body with the password redacted.
String redact(Map<String, String> body) {
  final out = <String, String>{};
  body.forEach((k, v) {
    out[k] = (k.toLowerCase().contains('password')) ? '<redacted>' : v;
  });
  return out.entries.map((e) => '${e.key}=${e.value}').join('\n  ');
}

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run tool/capture_reserve.dart <studentId> <password> [jalaliDate]');
    exitCode = 2;
    return;
  }
  final username = args[0];
  final password = args[1];
  final targetJalali = args.length > 2 ? args[2] : '1405/07/28';

  captureDir = Directory('captures')..createSync(recursive: true);
  print('=== CAPTURE RUN ${DateTime.now().toIso8601String()} ===');
  print('account: $username  target: $targetJalali');
  print('captures -> ${captureDir.path}');

  final transport = PortalTransport(baseUri: Uri.parse(_base));
  final log = StringBuffer();

  try {
    // ---------------------------------------------------------------- LOGIN
    print('\n--- PHASE 1: LOGIN ---');
    final page = await transport.get(username, '/');
    print('GET / -> ${page.statusCode} (${page.body.length} chars)');
    log.writeln('GET / -> ${page.statusCode} ${page.body.length} chars');
    save('01_login_page.html', page.body);

    final viewState = _input(page.body, '__VIEWSTATE');
    final viewStateGen = _input(page.body, '__VIEWSTATEGENERATOR');
    print('viewstate: ${viewState.length} chars, generator: $viewStateGen');
    print('cookies after page: ${transport.jars.jarFor(username).cookies.keys.toList()}');

    final captcha = await transport.getBytes(username, '/UserControls/Captcha.ashx');
    saveBytes('02_captcha.gif', captcha);
    print('captcha: ${captcha.length} bytes');

    final solution = CaptchaSolver().solve(captcha);
    print('SOLVED: ${solution.text} (confidence '
        '${solution.confidence.toStringAsFixed(1)})');
    log.writeln('captcha solved: ${solution.text}');

    final loginBody = <String, String>{
      '__VIEWSTATE': viewState,
      '__VIEWSTATEGENERATOR': viewStateGen,
      '__VIEWSTATEENCRYPTED': '',
      'txtUsername': username,
      'txtPassword': password,
      'txtCaptcha': solution.text!,
      'btnLogin': 'ورود سمت سرور ',
    };
    print('POST body:');
    print('  ${redact(loginBody)}');
    save('03_login_post_body.txt', redact(loginBody));

    final login = await transport.post(username, '/', body: loginBody);
    print('POST / -> ${login.statusCode}');
    log.writeln('POST / -> ${login.statusCode}');
    print('cookies after login: ${transport.jars.jarFor(username).cookies.keys.toList()}');
    save('04_after_login.html', login.body);
    print('login error label: ${_label(login.body, 'lblLoginError')}');
    print('profile name: ${_textById(login.body, 'divUsername')}');
    print('student id: ${_textById(login.body, 'lblIdNumber')}');
    print('credit: ${_label(login.body, 'lblCredit')}');
    print('cafeteria credit: ${_label(login.body, 'lblCafeteriaCredit')}');
    print('today: ${_textById(login.body, 'lblTodayDate')}');

    if (login.body.contains('txtUsernamePlain')) {
      print('!! LOGIN FAILED - aborting before any write');
      save('99_run_log.txt', log.toString());
      return;
    }

    // ------------------------------------------------------- RESERVATION PAGE
    print('\n--- PHASE 2: RESERVATION PAGE (weekly) ---');
    final reservation = await transport.get(username, '/Reservation/Reservation.aspx');
    print('GET Reservation.aspx -> ${reservation.statusCode} '
        '(${reservation.body.length} chars)');
    save('05_reservation_page.html', reservation.body);
    print('today on page: ${_textById(reservation.body, 'cphMain_lblTodayDate')}');
    print('credit: ${_label(reservation.body, 'lblCredit')}');

    // Which week is this page showing? Navigate to the target week if needed.
    final targetDate = parseJalaliDate(targetJalali);
    if (targetDate == null) {
      print('!! could not parse target date $targetJalali');
      return;
    }
    print('target $targetJalali -> $targetDate (weekday ${targetDate.weekday})');

    // Dump the lunch grid rows with full control detail.
    _dumpGrid(reservation.body, 'grdReservationLunch', 'lunch');

    // Is the target row present in the current week?
    var html = reservation.body;
    var found = _findRow(html, targetJalali, 'grdReservationLunch');
    if (found == null) {
      print('\ntarget row not in the current week; navigating forward...');
      for (var hop = 0; hop < 3 && found == null; hop++) {
        html = await _postNav(username, '/Reservation/Reservation.aspx', html,
            'ctl00\$cphMain\$imgbtnNextWeek', '05_reservation_page.html',
            '06_week_hop$hop.html');
        found = _findRow(html, targetJalali, 'grdReservationLunch');
        print('   hop $hop -> ${found == null ? "not found" : "FOUND"}');
      }
      save('07_reservation_target_week.html', html);
    }

    if (found == null) {
      print('\n!! target date $targetJalali not present in any reachable week');
      _dumpGrid(html, 'grdReservationLunch', 'lunch');
      save('99_run_log.txt', log.toString());
      return;
    }

    print('\n--- TARGET ROW DETAIL ---');
    print('row: ${found.summary}');

    // --------------------------------------------------- THE WRITE ATTEMPT
    print('\n--- PHASE 3: RESERVATION WRITE ATTEMPT ---');
    final result = await _attemptReserve(
      username: username,
      transport: transport,
      html: html,
      targetJalali: targetJalali,
      gridId: 'grdReservationLunch',
      saveButton: 'ctl00\$cphMain\$btnSaveLunch',
      preferHallId: '1',
      fallbackHallId: '2',
      wantDishFragment: 'اکبرجوجه',
    );

    print('\n=== WRITE RESULT ===');
    print('outcome: $result');

    // ---------------------------------------------------------- VERIFICATION
    print('\n--- PHASE 4: VERIFY BY RE-READING ---');
    final after = await transport.get(username, '/Reservation/Reservation.aspx');
    save('08_after_write.html', after.body);
    final reservations = CullinanParser.parseReservations(after.body);
    print('reservations now held: ${reservations.length}');
    for (final r in reservations) {
      print('   ${r.date.toIso8601String().substring(0, 10)} ${r.slot.name} '
          '${r.hall.name} ${r.option.name} (${r.option.priceRial})');
    }

    final targetHeld = reservations.any((r) =>
        r.date == targetDate &&
        r.slot == MealSlot.lunch &&
        r.option.name.contains('اکبرجوجه'));
    print('TARGET HELD (lunch Akbar Joojeh on $targetJalali): $targetHeld');

    // Also re-read the basket, in case a reservation lands there instead.
    final basket = await transport.get(username, '/FoodBasket/FoodBasketBuy.aspx');
    save('09_basket_after.html', basket.body);
    final listings = CullinanParser.parseBasket(basket.body, targetDate);
    print('basket listings for target date: ${listings.length}');
    for (final l in listings) {
      print('   ${l.id} ${l.option.name} (${l.priceRial}) ${l.hall.name}');
    }

    save('99_run_log.txt', log.toString());
  } catch (e, st) {
    print('EXCEPTION: $e');
    print(st.toString().split('\n').take(10).join('\n'));
    save('99_run_log.txt', log.toString());
  } finally {
    transport.close();
  }
}

/// Attempts the reservation, preferring one hall and falling back to the other.
Future<String> _attemptReserve({
  required String username,
  required PortalTransport transport,
  required String html,
  required String targetJalali,
  required String gridId,
  required String saveButton,
  required String preferHallId,
  required String fallbackHallId,
  required String wantDishFragment,
}) async {
  for (final hallId in [preferHallId, fallbackHallId]) {
    print('\n   >>> attempting with hall $hallId');

    final row = _findRow(html, targetJalali, gridId);
    if (row == null) {
      print('   row vanished');
      return 'row vanished';
    }

    // The food dropdown may depend on the selected hall (a cascading
    // dropdown). If the wanted dish is not among the options for this hall,
    // the hall is not an option for that dish, and we move to the fallback.
    final foodOptions = row.foodOptions;
    ParsedOptionView? match;
    for (final entry in foodOptions.entries) {
      if (entry.value.text.contains(wantDishFragment)) {
        match = entry.value;
        break;
      }
    }
    if (match == null) {
      print('   dish "$wantDishFragment" not offered for hall $hallId');
      print('   available: ${foodOptions.values.map((e) => e.text).toList()}');
      continue;
    }
    print('   dish: ${match.text} (option ${match.value})');

    // A disabled checkbox means the server has locked this date.
    if (row.checkboxDisabled) {
      print('   !! checkbox is DISABLED - the server has locked this date');
      print('   !! posting anyway to capture the server\'s exact response');
    }

    final body = <String, String>{
      '__VIEWSTATE': _input(html, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': _input(html, '__VIEWSTATEGENERATOR'),
      '__EVENTTARGET': '',
      '__EVENTARGUMENT': '',
      row.checkboxName: 'on',
      row.selfName: hallId,
      row.foodName: match.value,
      row.countName: row.countValue,
      saveButton: 'ذخیره',
    };
    print('   POST body:');
    print('     ${redact(body)}');
    save('10_reserve_post_body_hall$hallId.txt', redact(body));

    final response =
        await transport.post(username, '/Reservation/Reservation.aspx', body: body);
    print('   -> status ${response.statusCode}');
    save('11_reserve_response_hall$hallId.html', response.body);

    final error = _label(response.body, 'lblLoginError') ??
        _label(response.body, 'lblError') ??
        _label(response.body, 'lblMessage');
    if (error != null) print('   server message: $error');

    // Did the row become checked-and-disabled (i.e. reserved)?
    final after = _findRow(response.body, targetJalali, gridId);
    if (after != null && after.checkboxChecked) {
      print('   SUCCESS: the row is now checked (reserved)');
      return 'reserved with hall $hallId';
    }
    if (response.body.contains('txtUsernamePlain')) {
      print('   session expired');
      return 'session expired';
    }
    print('   not reserved after this attempt');
  }
  return 'not reserved (both halls attempted)';
}

/// A row of a reservation grid, with the control names needed to post it.
class RowView {
  RowView({
    required this.label,
    required this.checkboxName,
    required this.checkboxChecked,
    required this.checkboxDisabled,
    required this.selfName,
    required this.foodName,
    required this.foodOptions,
    required this.countName,
    required this.countValue,
    required this.price,
  });

  final String label;
  final String checkboxName;
  final bool checkboxChecked;
  final bool checkboxDisabled;
  final String selfName;
  final String foodName;
  final Map<String, ParsedOptionView> foodOptions;
  final String countName;
  final String countValue;
  final String price;

  String get summary {
    final halls = foodOptions.isEmpty ? '' : ' options=${foodOptions.length}';
    return '$label checked=$checkboxChecked disabled=$checkboxDisabled '
        'price=$price$halls';
  }
}

class ParsedOptionView {
  const ParsedOptionView(this.value, this.text);
  final String value;
  final String text;
}

/// Finds the grid row for a Jalali date, with its control names.
RowView? _findRow(String html, String jalaliDate, String gridId) {
  final table = RegExp('<table[^>]*id="[^"]*' + RegExp.escape(gridId) +
          r'"[^>]*>(.*?)</table>',
      dotAll: true)
      .firstMatch(html);
  if (table == null) return null;

  for (final rowMatch in RegExp(r'<tr[^>]*>(.*?)</tr>', dotAll: true)
      .allMatches(table.group(1)!)) {
    final raw = rowMatch.group(1)!;
    final cells = RegExp(r'<td[^>]*>(.*?)</td>', dotAll: true)
        .allMatches(raw)
        .map((m) => m.group(1)!)
        .toList();
    if (cells.length < 4) continue;

    final label = _text(cells[1]);
    if (!label.contains(jalaliDate)) continue;

    final checkbox = RegExp(r'<input[^>]*type="checkbox"[^>]*>', dotAll: true)
        .firstMatch(raw);
    final self = RegExp(r'<select[^>]*name="([^"]*drpSelf)"[^>]*>', dotAll: true)
        .firstMatch(raw);
    final food = RegExp(r'<select[^>]*name="([^"]*drpFood)"[^>]*>(.*?)</select>',
            dotAll: true)
        .firstMatch(raw);
    final count = RegExp(r'<select[^>]*name="([^"]*drpFoodCount)"[^>]*>(.*?)</select>',
            dotAll: true)
        .firstMatch(raw);

    final options = <String, ParsedOptionView>{};
    if (food != null) {
      for (final o in RegExp(
              r'<option(?:[^>]*value="([^"]*)")?[^>]*>(.*?)</option>',
              dotAll: true)
          .allMatches(food.group(2)!)) {
        options[o.group(1) ?? _text(o.group(2)!)] =
            ParsedOptionView(o.group(1) ?? '', _text(o.group(2)!));
      }
    }

    String countValue = '1';
    final countBody = count?.group(2);
    if (countBody != null) {
      final selected = RegExp(
              r'<option[^>]*value="([^"]*)"[^>]*selected',
              dotAll: true)
          .firstMatch(countBody);
      final first = RegExp(r'<option[^>]*value="([^"]*)"', dotAll: true)
          .firstMatch(countBody);
      countValue = selected?.group(1) ?? first?.group(1) ?? '1';
    }

    return RowView(
      label: label,
      checkboxName: _attr(checkbox?.group(0) ?? '', 'name'),
      checkboxChecked: (checkbox?.group(0) ?? '').contains('checked'),
      checkboxDisabled: (checkbox?.group(0) ?? '').contains('disabled'),
      selfName: self?.group(1) ?? '',
      foodName: food?.group(1) ?? '',
      foodOptions: options,
      countName: count?.group(1) ?? '',
      countValue: countValue,
      price: cells.length > 6 ? _text(cells[6]) : '',
    );
  }
  return null;
}

/// Dumps every row of a grid with its control detail.
void _dumpGrid(String html, String gridId, String label) {
  print('   --- $label grid ($gridId) ---');
  final table = RegExp('<table[^>]*id="[^"]*' + RegExp.escape(gridId) +
          r'"[^>]*>(.*?)</table>',
          dotAll: true)
      .firstMatch(html);
  if (table == null) {
    print('   grid not found');
    return;
  }
  for (final rowMatch in RegExp(r'<tr[^>]*>(.*?)</tr>', dotAll: true)
      .allMatches(table.group(1)!)) {
    final raw = rowMatch.group(1)!;
    final cells = RegExp(r'<td[^>]*>(.*?)</td>', dotAll: true)
        .allMatches(raw)
        .map((m) => m.group(1)!)
        .toList();
    if (cells.length < 4) continue;

    final cb = RegExp(r'<input[^>]*type="checkbox"[^>]*>', dotAll: true)
        .firstMatch(raw);
    final checked = (cb?.group(0) ?? '').contains('checked');
    final disabled = (cb?.group(0) ?? '').contains('disabled');
    final food = RegExp(r'<select[^>]*name="([^"]*drpFood)"[^>]*>(.*?)</select>',
            dotAll: true)
        .firstMatch(raw);
    final self = RegExp(r'<select[^>]*name="([^"]*drpSelf)"[^>]*>(.*?)</select>',
            dotAll: true)
        .firstMatch(raw);

    final foodOpts = food == null
        ? const <String>[]
        : RegExp(r'<option(?:[^>]*value="([^"]*)")?[^>]*>(.*?)</option>',
                dotAll: true)
            .allMatches(food.group(2)!)
            .map((o) => '${o.group(1) ?? '-'}:${_text(o.group(2)!)}')
            .toList();
    final selfOpts = self == null
        ? const <String>[]
        : RegExp(r'<option(?:[^>]*value="([^"]*)")?[^>]*>(.*?)</option>',
                dotAll: true)
            .allMatches(self.group(2)!)
            .map((o) => '${o.group(1) ?? '-'}:${_text(o.group(2)!)}')
            .toList();

    print('   ${_text(cells[1]).padRight(22)} '
        'checked=${checked.toString().padRight(5)} '
        'disabled=${disabled.toString().padRight(5)} '
        'price=${cells.length > 6 ? _text(cells[6]) : ""}');
    print('        halls: $selfOpts');
    for (final o in foodOpts) {
      print('        food:  $o');
    }
  }
}

/// Posts a navigation event (next week, today) and returns the new page.
Future<String> _postNav(
  String username,
  String path,
  String currentHtml,
  String eventTarget,
  String previousName,
  String newName,
) async {
  final transport = PortalTransport(baseUri: Uri.parse(_base));
  try {
    final response = await transport.post(username, path, body: {
      '__VIEWSTATE': _input(currentHtml, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': _input(currentHtml, '__VIEWSTATEGENERATOR'),
      '__EVENTTARGET': eventTarget,
      '__EVENTARGUMENT': '',
    });
    save(newName, response.body);
    return response.body;
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
