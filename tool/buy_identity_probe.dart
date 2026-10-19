/// READ-ONLY probe: what exactly is a buy-page listing?
///
/// ## The puzzle
///
/// For date 1405/07/28 the buy page offered breakfast option **62798**, while
/// the weekly reservation grid for the *same* date offers **62737**. The
/// lunch row agrees (62738 in both). So one row matches the official menu and
/// the other does not.
///
/// Three explanations, with very different consequences:
///
///   (a) The buy page is a MARKETPLACE of released meals, and a released meal
///       carries its own option id. -> the hunt's dish list must come from
///       the buy page, never from the official menu.
///   (b) The buy page's date filter is NOT applied, and the rows belong to a
///       different date. -> the hunt would buy the WRONG DAY's meal.
///   (c) The portal re-publishes the menu for a lapsed date. -> the option id
///       is still date-correct, and the hunt may use the official menu.
///
/// ## The test
///
/// Map option ids to dates by reading EVERY week of the reservation grid, then
/// look up 62798. If it belongs to another date, (b) is live and the date
/// filter is broken. If it belongs to 1405/07/28, (a) or (c) holds and the
/// buy page is date-correct.
///
/// Also reports which week the buy page's rows correspond to.
///
/// ## Why it is safe
///
/// GETs and the grid's own week-navigation postbacks. No `btnSave` anywhere,
/// so nothing is purchased, reserved, listed or cancelled.
///
/// Usage: `dart run tool/buy_identity_probe.dart <studentId> <password>
// Diagnostic probe: stdout printing is the entire point.
// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings

library;

import 'dart:io';

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/transport/http_transport.dart';

const _base = 'https://nut.uk.ac.ir/';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run tool/buy_identity_probe.dart <studentId> <password>');
    exitCode = 2;
    return;
  }
  final username = args[0];
  final password = args[1];

  final transport = PortalTransport(baseUri: Uri.parse(_base));

  try {
    // --- login ---
    final page = await transport.get(username, '/');
    final captcha =
        await transport.getBytes(username, '/UserControls/Captcha.ashx');
    final solution = CaptchaSolver().solve(captcha);
    final login = await transport.post(username, '/', body: {
      '__VIEWSTATE': _input(page.body, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': _input(page.body, '__VIEWSTATEGENERATOR'),
      '__EVENTTARGET': '',
      '__EVENTARGUMENT': '',
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

    // --- walk the reservation grid forward, mapping option ids to dates ---
    final idToDate = <String, String>{};
    var html =
        (await transport.get(username, '/Reservation/Reservation.aspx')).body;

    for (var week = 0; week < 4; week++) {
      final weekLabel = _label(html, 'lblWeekDate') ?? '?';
      print('\n=== reservation week $week: $weekLabel ===');
      for (final grid in [
        'grdReservationBreakfast',
        'grdReservationLunch',
        'grdReservationDinner',
      ]) {
        for (final row in _gridRows(html, grid)) {
          final date = RegExp(r'\d{4}/\d{2}/\d{2}').firstMatch(row.label);
          if (date == null) continue;
          for (final option in row.foods) {
            idToDate.putIfAbsent(option, () => '${date.group(0)} ${row.slot}');
          }
          if (row.foods.any((f) => f == '-1')) continue;
          print('  ${row.slot.padRight(10)} ${date.group(0)} '
              'foods=${row.foods.join(",")} halls=${row.halls.join(",")} '
              'checked=${row.checked} amount=${row.amount}');
        }
      }

      // Step to the next week.
      final next = await _nextWeek(transport, username, html);
      if (next == null) break;
      html = next;
    }

    print('\n=== the option id map ===');
    final ids = idToDate.keys.toList()..sort();
    for (final id in ids) {
      print('  $id -> ${idToDate[id]}');
    }

    // --- the buy page, and what its options mean ---
    final buy =
        (await transport.get(username, '/FoodBasket/FoodBasketBuy.aspx')).body;
    print('\n=== the BUY page ===');
    print('  txtDate: ${_value(buy, "cphMain_txtDate")}');
    for (final row in _buyRows(buy)) {
      final meaning = row.foods
          .map((f) => f == '-1' ? '-1' : '$f(${idToDate[f] ?? "UNKNOWN DATE"})')
          .join(', ');
      print('  ${row.slot.padRight(10)} $meaning');
    }
  } catch (e, st) {
    print('EXCEPTION: $e');
    print(st.toString().split('\n').take(8).join('\n'));
  } finally {
    transport.close();
  }
}

/// The reservation grid's own "next week" postback.
Future<String?> _nextWeek(
  PortalTransport transport,
  String username,
  String html,
) async {
  // The button is an image input, so the postback carries its .x/.y.
  final body = <String, String>{
    '__VIEWSTATE': _input(html, '__VIEWSTATE'),
    '__VIEWSTATEGENERATOR': _input(html, '__VIEWSTATEGENERATOR'),
    '__EVENTTARGET': '',
    '__EVENTARGUMENT': '',
    'ctl00\$cphMain\$imgbtnNextWeek.x': '1',
    'ctl00\$cphMain\$imgbtnNextWeek.y': '1',
  };
  final response = await transport.post(
    username,
    '/Reservation/Reservation.aspx',
    body: body,
  );
  final label = _label(response.body, 'lblWeekDate');
  if (label == null) return null;
  if (label == _label(html, 'lblWeekDate')) return null;
  return response.body;
}

class _Row {
  _Row(this.slot, this.label, this.foods, this.halls, this.checked,
      this.amount);

  final String slot;
  final String label;
  final List<String> foods;
  final List<String> halls;
  final bool checked;
  final String amount;
}

List<_Row> _gridRows(String html, String grid) {
  final t = RegExp('<table[^>]*id="[^"]*' + grid + r'"[^>]*>(.*?)</table>',
          dotAll: true)
      .firstMatch(html);
  if (t == null) return const [];

  final out = <_Row>[];
  for (final m in RegExp(r'<tr[^>]*>(.*?)</tr>', dotAll: true)
      .allMatches(t.group(1)!)) {
    final raw = m.group(1)!;
    final cells = RegExp(r'<td[^>]*>(.*?)</td>', dotAll: true)
        .allMatches(raw)
        .map((c) => c.group(1)!)
        .toList();
    if (cells.length < 4) continue;

    final cb = RegExp(r'<input[^>]*type="checkbox"[^>]*>', dotAll: true)
        .firstMatch(raw);
    final tag = cb?.group(0) ?? '';

    out.add(_Row(
      _slotOf(grid),
      _text(cells[1]),
      _optionValues(raw, 'drpFood'),
      _optionValues(raw, 'drpSelf'),
      tag.contains('checked'),
      cells.length > 6 ? _text(cells[6]) : '',
    ));
  }
  return out;
}

List<_Row> _buyRows(String html) {
  final t = RegExp('<table[^>]*id="[^"]*grdFoodBasketReservation"[^>]*>(.*?)</table>',
          dotAll: true)
      .firstMatch(html);
  if (t == null) return const [];

  final out = <_Row>[];
  for (final m in RegExp(r'<tr[^>]*>(.*?)</tr>', dotAll: true)
      .allMatches(t.group(1)!)) {
    final raw = m.group(1)!;
    final cells = RegExp(r'<td[^>]*>(.*?)</td>', dotAll: true)
        .allMatches(raw)
        .map((c) => c.group(1)!)
        .toList();
    if (cells.length < 4) continue;

    final cb = RegExp(r'<input[^>]*type="checkbox"[^>]*>', dotAll: true)
        .firstMatch(raw);
    final tag = cb?.group(0) ?? '';

    out.add(_Row(
      _text(cells[1]),
      '',
      _optionValues(raw, 'drpFood'),
      _optionValues(raw, 'drpSelf'),
      tag.contains('checked'),
      cells.length > 6 ? _text(cells[6]) : '',
    ));
  }
  return out;
}

String _slotOf(String grid) => switch (grid) {
      'grdReservationBreakfast' => 'صبحانه',
      'grdReservationLunch' => 'ناهار',
      _ => 'شام',
    };

List<String> _optionValues(String html, String suffix) {
  final s = RegExp('<select[^>]*name="[^"]*' + RegExp.escape(suffix) +
          r'"[^>]*>(.*?)</select>',
          dotAll: true)
      .firstMatch(html);
  if (s == null) return const [];
  return RegExp(r'<option[^>]*value="([^"]*)"')
      .allMatches(s.group(1)!)
      .map((o) => o.group(1)!)
      .toList();
}

String _text(String html) => html
    .replaceAll(RegExp(r'<[^>]*>'), ' ')
    .replaceAll('&nbsp;', ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String _input(String html, String id) {
  final m = RegExp('id="' + RegExp.escape(id) + r'"[^>]*value="([^"]*)"')
      .firstMatch(html);
  return m?.group(1) ?? '';
}

String _value(String html, String id) {
  final m = RegExp('id="[^"]*' + RegExp.escape(id) + r'"[^>]*value="([^"]*)"')
      .firstMatch(html);
  if (m != null) return m.group(1)!;
  final inner = RegExp('id="[^"]*' + RegExp.escape(id) + r'"[^>]*>([^<]*)<')
      .firstMatch(html);
  return inner?.group(1)?.trim() ?? '';
}

String? _label(String html, String id) {
  final m = RegExp('<label[^>]*id="' + RegExp.escape(id) +
          r'"[^>]*>(.*?)</label>',
          dotAll: true)
      .firstMatch(html);
  if (m == null) return null;
  final t = m.group(1)!.replaceAll(RegExp(r'\s+'), ' ').trim();
  return t.isEmpty ? null : t;
}
