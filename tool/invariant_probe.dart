/// READ-ONLY probe: does the portal enforce "one meal per slot per day" across
/// the weekly reservation and the Food Basket?
///
/// The product owner asserts: a student who already holds a regular weekly
/// reservation cannot buy from the basket for that same slot and date, and
/// vice versa.
///
/// The account conveniently holds meals in all three slots on different dates,
/// so each combination can be tested:
///
///   1405/07/28 - holds DINNER  (خوراک سالاد الویه)
///   1405/07/30 - holds LUNCH   (شوید پلو با تن ماهی)
///   1405/08/03 - holds BREAKFAST (and had a cancel on it)
///
/// For each, this reports what the weekly grid says is held and what the
/// basket offers. If the basket offers an option for a slot the account
/// already holds, the PORTAL does not enforce the cross-source rule, and our
/// app must.
///
/// Usage: `dart run tool/invariant_probe.dart <studentId> <password>`
// Read-only diagnostic probe.
// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings

library;

import 'dart:io';

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/transport/http_transport.dart';

const _base = 'https://nut.uk.ac.ir/';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run tool/invariant_probe.dart <studentId> <password>');
    exitCode = 2;
    return;
  }
  final username = args[0];
  final password = args[1];

  final transport = PortalTransport(baseUri: Uri.parse(_base));
  const dates = ['1405/07/28', '1405/07/30', '1405/08/03'];

  try {
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
    print('login OK; credit: ${_label(login.body, 'lblCredit')}');

    // What the WEEKLY grid says the account holds, per date and slot.
    final weekly = await transport.get(username, '/Reservation/Reservation.aspx');
    final held = _heldByDate(weekly.body);
    print('\n=== held per the WEEKLY grid ===');
    for (final date in dates) {
      print('  $date: ${held[date] ?? "(nothing held)"}');
    }

    // What the BASKET offers for each date.
    final buy = await transport.get(username, '/FoodBasket/FoodBasketBuy.aspx');
    for (final date in dates) {
      final filtered = await _setDate(transport, username, buy.body, date);
      print('\n=== basket offers for $date '
          '(page date field = ${_value(filtered, 'cphMain_txtDate')}) ===');
      for (final row in _buyRows(filtered)) {
        final slot = _slotOf(row.$1);
        final alreadyHeld = (held[date] ?? '').contains(slot);
        final marker = alreadyHeld ? '   <== ACCOUNT ALREADY HOLDS THIS SLOT' : '';
        print('  ${row.$1.padRight(8)} options=${row.$2.length}$marker');
        for (final o in row.$2) {
          print('      $o');
        }
      }
    }
  } catch (e, st) {
    print('EXCEPTION: $e');
    print(st.toString().split('\n').take(8).join('\n'));
  } finally {
    transport.close();
  }
}

/// The meals held, keyed by Jalali date, as "slot: dish" strings.
Map<String, String> _heldByDate(String html) {
  final out = <String, String>{};
  for (final entry in [
    ('grdReservationBreakfast', 'breakfast'),
    ('grdReservationLunch', 'lunch'),
    ('grdReservationDinner', 'dinner'),
  ]) {
    final t = RegExp('<table[^>]*id="[^"]*' + entry.$1 + r'"[^>]*>(.*?)</table>',
            dotAll: true)
        .firstMatch(html);
    if (t == null) continue;
    for (final m in RegExp(r'<tr[^>]*>(.*?)</tr>', dotAll: true)
        .allMatches(t.group(1)!)) {
      final raw = m.group(1)!;
      if (!raw.contains('checked="checked"')) continue;
      final cells = RegExp(r'<td[^>]*>(.*?)</td>', dotAll: true)
          .allMatches(raw)
          .map((c) => c.group(1)!)
          .toList();
      if (cells.length < 4) continue;
      final label = _text(cells[1]);
      final d = RegExp(r'\d{4}/\d{2}/\d{2}').firstMatch(label)?.group(0);
      if (d == null) continue;
      final dish = _text(cells[3]);
      out[d] = '${out[d] ?? ""}${out.containsKey(d) ? ", " : ""}'
          '${entry.$2}: $dish';
    }
  }
  return out;
}

/// The basket rows: (meal name, option descriptions).
List<(String, List<String>)> _buyRows(String html) {
  final t = RegExp('<table[^>]*id="[^"]*grdFoodBasketReservation"[^>]*>(.*?)</table>',
          dotAll: true)
      .firstMatch(html);
  if (t == null) return const [];

  final out = <(String, List<String>)>[];
  for (final m in RegExp(r'<tr[^>]*>(.*?)</tr>', dotAll: true)
      .allMatches(t.group(1)!)) {
    final raw = m.group(1)!;
    final cells = RegExp(r'<td[^>]*>(.*?)</td>', dotAll: true)
        .allMatches(raw)
        .map((c) => c.group(1)!)
        .toList();
    if (cells.length < 8) continue;

    final meal = _text(cells[1]);
    final food = RegExp(r'<select[^>]*name="[^"]*drpFood"[^>]*>(.*?)</select>',
            dotAll: true)
        .firstMatch(raw);
    final options = <String>[];
    if (food != null) {
      for (final o in RegExp(r'<option[^>]*value="([^"]*)"[^>]*>(.*?)</option>',
              dotAll: true)
          .allMatches(food.group(1)!)) {
        options.add('${o.group(1)}=${_text(o.group(2)!)}');
      }
    }
    out.add((meal, options));
  }
  return out;
}

String _slotOf(String meal) => switch (meal.trim()) {
      'صبحانه' => 'breakfast',
      'ناهار' => 'lunch',
      'شام' => 'dinner',
      _ => meal.trim(),
    };

Future<String> _setDate(
  PortalTransport transport,
  String username,
  String html,
  String date,
) async {
  final resp = await transport.post(username, '/FoodBasket/FoodBasketBuy.aspx',
      body: {
        '__VIEWSTATE': _input(html, '__VIEWSTATE'),
        '__VIEWSTATEGENERATOR': _input(html, '__VIEWSTATEGENERATOR'),
        '__EVENTTARGET': '',
        '__EVENTARGUMENT': '',
        'ctl00\$cphMain\$txtDate': date,
        'ctl00\$cphMain\$imgbtnGoToDate.x': '1',
        'ctl00\$cphMain\$imgbtnGoToDate.y': '1',
      });
  return resp.body;
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
  final m = RegExp('<label[^>]*id="' + RegExp.escape(id) + r'"[^>]*>(.*?)</label>',
          dotAll: true)
      .firstMatch(html);
  final t = m?.group(1)?.replaceAll(RegExp(r'\s+'), ' ').trim();
  return (t == null || t.isEmpty) ? null : t;
}
