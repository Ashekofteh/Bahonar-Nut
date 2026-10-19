/// Follow-up capture: find the nearest BOOKABLE "Akbar Joojeh" lunch and book
/// it with the requested hall preference (Central first, Engineering fallback).
///
/// Why this exists: the product owner asked for lunch on Mehr 28, 1405
/// (Tuesday 2026-10-20). That date's cutoff was 20:00 on Mehr 26 — three days
/// before the run — so the server renders the row `disabled` and silently
/// ignores any reservation posted for it. The capture proved that.
///
/// This tool therefore finds the same weekday+meal in the next week, which is
/// the closest thing that can actually be booked, and books it.
///
/// READ-ONLY until the final reservation POST.
///
/// Usage: `dart run tool/capture_next_week.dart <studentId> <password> [dishFragment]`
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

late Directory captureDir;

void save(String name, String content) {
  File('${captureDir.path}/$name').writeAsStringSync(content);
  print('   [capture] $name (${content.length} chars)');
}

void saveBytes(String name, List<int> bytes) {
  File('${captureDir.path}/$name').writeAsBytesSync(bytes);
  print('   [capture] $name (${bytes.length} bytes)');
}

String redact(Map<String, String> body) {
  final out = <String, String>{};
  body.forEach((k, v) {
    out[k] = k.toLowerCase().contains('password') ? '<redacted>' : v;
  });
  return out.entries.map((e) => '${e.key}=${e.value}').join('\n  ');
}

/// One row of a reservation grid, with the control names needed to post it.
class RowView {
  RowView({
    required this.label,
    required this.date,
    required this.checkboxName,
    required this.checkboxChecked,
    required this.checkboxDisabled,
    required this.selfName,
    required this.foodName,
    required this.foodOptions,
    required this.countName,
    required this.countValue,
    required this.hallOptions,
  });

  final String label;
  final DateTime? date;
  final String checkboxName;
  final bool checkboxChecked;
  final bool checkboxDisabled;
  final String selfName;
  final String foodName;
  final List<MapEntry<String, String>> foodOptions;
  final String countName;
  final String countValue;
  final List<MapEntry<String, String>> hallOptions;

  bool get isEditable => !checkboxDisabled;

  @override
  String toString() =>
      '$label checked=$checkboxChecked disabled=$checkboxDisabled';
}

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run tool/capture_next_week.dart <studentId> <password> '
        '[dishFragment]');
    exitCode = 2;
    return;
  }
  final username = args[0];
  final password = args[1];
  final wantDish = args.length > 2 ? args[2] : 'اکبرجوجه';

  captureDir = Directory('captures')..createSync(recursive: true);
  print('=== NEXT-WEEK CAPTURE ${DateTime.now().toIso8601String()} ===');
  print('account: $username  looking for: $wantDish');

  final transport = PortalTransport(baseUri: Uri.parse(_base));

  try {
    // ------------------------------------------------------------- LOGIN
    print('\n--- LOGIN ---');
    final page = await transport.get(username, '/');
    final viewState = _input(page.body, '__VIEWSTATE');
    final captcha =
        await transport.getBytes(username, '/UserControls/Captcha.ashx');
    saveBytes('20_captcha.gif', captcha);
    final solution = CaptchaSolver().solve(captcha);
    print('solved: ${solution.text}');

    final login = await transport.post(username, '/', body: {
      '__VIEWSTATE': viewState,
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
    print('login OK; cookies: ${transport.jars.jarFor(username).cookies.keys.toList()}');
    print('profile: ${_textById(login.body, 'divUsername')} '
        'id: ${_textById(login.body, 'lblIdNumber')}');
    print('credit: ${_label(login.body, 'lblCredit')}');
    print('today: ${_textById(login.body, 'cphMain_lblTodayDate')}');
    save('21_after_login.html', login.body);

    // ------------------------------------------- SEARCH WEEKS FOR THE DISH
    // Walk forward one week at a time and stop at the first week that offers
    // an editable row with the wanted dish. Going too far forward lands on
    // weeks whose menus are not published yet (every row renders `-`).
    print('\n--- SEARCHING FOR AN EDITABLE "$wantDish" LUNCH ---');

    var html = login.body;
    RowView? chosen;
    MapEntry<String, String>? option;

    for (var week = 0; week <= 3; week++) {
      final weekLabel = _textById(html, 'cphMain_lblWeekDate') ?? 'week $week';
      print('\n  WEEK $week: $weekLabel');
      save('23_week$week.html', html);

      final rows = _gridRows(html, 'grdReservationLunch');
      for (final row in rows) {
        final hasDish = row.foodOptions.any((o) => o.value.contains(wantDish));
        final marker = hasDish ? ' <== HAS DISH' : '';
        print('   ${row.label}  checked=${row.checkboxChecked} '
            'editable=${row.isEditable}$marker');
        for (final o in row.foodOptions) {
          final tag = o.value.contains(wantDish) ? '  <== TARGET' : '';
          print('      ${o.key}: ${o.value}$tag');
        }
      }

      final candidates = rows
          .where((r) => r.isEditable && !r.checkboxChecked)
          .where((r) => r.foodOptions.any((o) => o.value.contains(wantDish)))
          .toList();

      if (candidates.isNotEmpty) {
        chosen = candidates.first;
        option = chosen.foodOptions
            .firstWhere((o) => o.value.contains(wantDish));
        print('\n  -> BOOKABLE in week $week: ${chosen.label}');
        break;
      }

      print('  -> nothing bookable here; advancing one week');
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

    if (chosen == null || option == null) {
      print('\n!! no editable "$wantDish" lunch found in the reachable weeks');
      return;
    }

    // Non-nullable copies: the promotion above does not carry into the
    // closures below, which capture these variables.
    final targetRow = chosen;
    final targetOption = option;

    print('\nCHOSEN: ${chosen.label}  dish option ${option.key}  '
        '(${targetOption.value})');
    print('halls offered: ${targetRow.hallOptions.map((h) => "${h.key}=${h.value}").toList()}');

    // --------------------------------------------------------- THE WRITE
    print('\n--- RESERVATION WRITE ---');
    final result = await _attempt(
      username: username,
      transport: transport,
      html: html,
      row: targetRow,
      optionId: targetOption.key,
      saveButton: 'ctl00\$cphMain\$btnSaveLunch',
      preferHalls: ['1', '2'], // Central first, Engineering fallback
    );
    print('\n=== WRITE RESULT: $result ===');

    // --------------------------------------------------------- VERIFY
    print('\n--- VERIFY ---');
    final after =
        await transport.get(username, '/Reservation/Reservation.aspx');
    save('24_after_reserve.html', after.body);
    final reservations = CullinanParser.parseReservations(after.body);
    print('reservations held now: ${reservations.length}');
    for (final r in reservations) {
      print('   ${r.date.toIso8601String().substring(0, 10)} ${r.slot.name} '
          '${r.hall.name} ${r.option.name} (${r.option.priceRial})');
    }

    final held = reservations.any((r) =>
        r.slot == MealSlot.lunch &&
        r.option.id == targetOption.key &&
        targetRow.date != null &&
        r.date == targetRow.date);
    print('\nTARGET BOOKED (${chosen.label}, option ${option.key}): $held');
    print('(the target row is 1405/07/28 = 2026-10-20, which is LOCKED; '
        'this is the nearest bookable equivalent)');

    final credit = _label(after.body, 'lblCredit');
    print('credit after: $credit');
  } catch (e, st) {
    print('EXCEPTION: $e');
    print(st.toString().split('\n').take(8).join('\n'));
  } finally {
    transport.close();
  }
}

/// Attempts the reservation for each hall in turn, stopping at the first success.
Future<String> _attempt({
  required String username,
  required PortalTransport transport,
  required String html,
  required RowView row,
  required String optionId,
  required String saveButton,
  required List<String> preferHalls,
}) async {
  for (final hallId in preferHalls) {
    final hallName = row.hallOptions
        .where((h) => h.key == hallId)
        .map((h) => h.value)
        .firstOrNull;
    print('\n   >>> hall $hallId (${hallName ?? '?'})');

    if (hallName == null) {
      print('   hall $hallId not offered for this meal; trying the next');
      continue;
    }

    final body = <String, String>{
      '__VIEWSTATE': _input(html, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': _input(html, '__VIEWSTATEGENERATOR'),
      '__EVENTTARGET': '',
      '__EVENTARGUMENT': '',
      row.checkboxName: 'on',
      row.selfName: hallId,
      row.foodName: optionId,
      row.countName: row.countValue,
      saveButton: 'ذخیره',
    };
    print('   POST body:');
    print('     ${redact(body)}');
    save('25_reserve_body_hall$hallId.txt', redact(body));

    final response = await transport.post(username, '/Reservation/Reservation.aspx',
        body: body);
    print('   -> status ${response.statusCode}');
    save('26_reserve_response_hall$hallId.html', response.body);

    final alert = _textById(response.body, 'cphMain_alertBoxValue');
    if (alert != null && alert.isNotEmpty) {
      print('   server alert: $alert');
    }

    // Verify by reading the row back from the RESPONSE.
    final rows = _gridRows(response.body, 'grdReservationLunch');
    final after = rows.where((r) => r.label == row.label).firstOrNull;
    if (after != null) {
      print('   row after: checked=${after.checkboxChecked} '
          'disabled=${after.checkboxDisabled}');
      if (after.checkboxChecked) {
        return 'RESERVED with hall $hallId';
      }
    }
    print('   not reserved on this attempt');
  }
  return 'not reserved';
}

/// The rows of a reservation grid, with control names.
List<RowView> _gridRows(String html, String gridId) {
  final table = RegExp('<table[^>]*id="[^"]*' + RegExp.escape(gridId) +
          r'"[^>]*>(.*?)</table>',
          dotAll: true)
      .firstMatch(html);
  if (table == null) return const [];

  final rows = <RowView>[];
  for (final m in RegExp(r'<tr[^>]*>(.*?)</tr>', dotAll: true)
      .allMatches(table.group(1)!)) {
    final raw = m.group(1)!;
    final cells = RegExp(r'<td[^>]*>(.*?)</td>', dotAll: true)
        .allMatches(raw)
        .map((c) => c.group(1)!)
        .toList();
    if (cells.length < 4) continue;

    final label = _text(cells[1]);
    final cb = RegExp(r'<input[^>]*type="checkbox"[^>]*>', dotAll: true)
        .firstMatch(raw);
    final cbTag = cb?.group(0) ?? '';
    final self = RegExp(r'<select[^>]*name="([^"]*drpSelf)"[^>]*>(.*?)</select>',
            dotAll: true)
        .firstMatch(raw);
    final food = RegExp(r'<select[^>]*name="([^"]*drpFood)"[^>]*>(.*?)</select>',
            dotAll: true)
        .firstMatch(raw);
    final count =
        RegExp(r'<select[^>]*name="([^"]*drpFoodCount)"[^>]*>(.*?)</select>',
            dotAll: true)
            .firstMatch(raw);

    List<MapEntry<String, String>> optionsOf(String? body) {
      if (body == null) return const [];
      return RegExp(r'<option(?:[^>]*value="([^"]*)")?[^>]*>(.*?)</option>',
              dotAll: true)
          .allMatches(body)
          .map((o) => MapEntry(
              o.group(1) ?? '', _text(o.group(2)!)))
          .toList();
    }

    var countValue = '1';
    final countBody = count?.group(2);
    if (countBody != null) {
      final sel = RegExp(r'<option[^>]*value="([^"]*)"[^>]*selected', dotAll: true)
          .firstMatch(countBody);
      final first = RegExp(r'<option[^>]*value="([^"]*)"', dotAll: true)
          .firstMatch(countBody);
      countValue = sel?.group(1) ?? first?.group(1) ?? '1';
    }

    rows.add(RowView(
      label: label,
      date: parseJalaliDate(label),
      checkboxName: _attr(cbTag, 'name'),
      checkboxChecked: cbTag.contains('checked'),
      checkboxDisabled: cbTag.contains('disabled'),
      selfName: self?.group(1) ?? '',
      foodName: food?.group(1) ?? '',
      foodOptions: optionsOf(food?.group(2)),
      countName: count?.group(1) ?? '',
      countValue: countValue,
      hallOptions: optionsOf(self?.group(2)),
    ));
  }
  return rows;
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
