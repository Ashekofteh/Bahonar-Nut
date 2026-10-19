/// ZERO-COST probe: does the portal enforce "one meal per slot per date" across
/// the weekly reservation and the Food Basket?
///
/// ## Why this cannot spend money
///
/// The account's balance is **0 Rial** and the cheapest meal in the portal costs
/// 150,000. No purchase can succeed, so the attempt is free of financial
/// consequence. What it does reveal is the server's VALIDATION ORDER and its
/// ERROR MESSAGES — which decide whether our app must enforce the invariant
/// itself.
///
/// ## What the read-only probe already showed
///
/// For 1405/07/30 the account HOLDS lunch (option 62759, شوید پلو با تن ماهی)
/// and the basket STILL OFFERS that exact option for that exact date and slot.
/// The basket dropdown is therefore **not** filtered by what the user already
/// holds. Whether the server refuses at POST time is what this probes.
///
/// One request. It cannot spend.
///
/// Usage: `dart run tool/invariant_enforcement.dart <studentId> <password>
// Diagnostic probe: stdout printing is the entire point.
// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings

library;

import 'dart:io';

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/transport/http_transport.dart';

const _base = 'https://nut.uk.ac.ir/';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run tool/invariant_enforcement.dart <studentId> <password>');
    exitCode = 2;
    return;
  }
  final username = args[0];
  final password = args[1];

  final transport = PortalTransport(baseUri: Uri.parse(_base));

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
    final credit = _credit(login.body);
    print('credit: $credit  (must be 0 for this probe to be costless)');
    if (credit != 0) {
      print('!! balance is not 0 - ABORTING, this probe could spend money');
      return;
    }

    // The date the account already holds LUNCH for: 1405/07/30, option 62759.
    final buy = await transport.get(username, '/FoodBasket/FoodBasketBuy.aspx');
    final filtered = await _setDate(transport, username, buy.body, '1405/07/30');
    print('\n=== basket for 1405/07/30 (the account already holds LUNCH) ===');
    for (final row in _buyRows(filtered)) {
      print('  ${row.$1.padRight(8)} ${row.$2}');
    }

    // Build the post for the slot the account already holds.
    final body = <String, String>{
      '__VIEWSTATE': _input(filtered, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': _input(filtered, '__VIEWSTATEGENERATOR'),
      '__VIEWSTATEENCRYPTED': _input(filtered, '__VIEWSTATEENCRYPTED'),
      '__EVENTTARGET': '',
      '__EVENTARGUMENT': '',
      'ctl00\$cphMain\$txtDate': '1405/07/30',
      'ctl00\$cphMain\$grdFoodBasketReservation\$ctl03\$chkReserve': 'on',
      'ctl00\$cphMain\$grdFoodBasketReservation\$ctl03\$drpSelf': '1',
      'ctl00\$cphMain\$grdFoodBasketReservation\$ctl03\$drpFood': '62759',
      'ctl00\$cphMain\$grdFoodBasketReservation\$ctl03\$drpFoodCount': '1',
      'ctl00\$cphMain\$btnSave': 'ذخیره',
    };

    print('\n=== attempting to buy a meal the account ALREADY HOLDS ===');
    print('(cannot spend: balance is 0)');
    final resp = await transport.post(username, '/FoodBasket/FoodBasketBuy.aspx',
        body: body);
    print('status: ${resp.statusCode}');
    save('90_invariant_attempt_response.html', resp.body);

    // The server's complaint, if any.
    for (final id in [
      'cphMain_alertBoxValue',
      'cphMain_lblError',
      'lblError',
      'cphMain_lblMessage',
      'cphMain_divError',
    ]) {
      final v = _textById(resp.body, id);
      if (v != null && v.isNotEmpty) {
        print('  $id = $v');
      }
    }
    print('  alertBox raw = ${_rawById(resp.body, 'cphMain_alertBoxValue')}');

    // Any visible message anywhere in the page.
    final plain = resp.body
        .replaceAll(RegExp(r'<script.*?</script>', dotAll: true), ' ')
        .replaceAll(RegExp(r'<style.*?</style>', dotAll: true), ' ')
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ');
    for (final kw in [
      'اعتبار',
      'موجودی',
      'کافی',
      'رزرو',
      'قبلی',
      'امکان',
      'ناموفق',
      'خطا',
    ]) {
      final i = plain.indexOf(kw);
      if (i >= 0) {
        final s = i > 120 ? i - 120 : 0;
        print('  [$kw] ...${plain.substring(s, i + 160)}...');
      }
    }

    // And confirm the credit did not move.
    final after = await transport.get(username, '/Reservation/Reservation.aspx');
    print('\ncredit after the attempt: ${_credit(after.body)}');
  } catch (e, st) {
    print('EXCEPTION: $e');
    print(st.toString().split('\n').take(8).join('\n'));
  } finally {
    transport.close();
  }
}

void save(String name, String content) {
  File('captures/$name').writeAsStringSync(content);
  print('   [capture] captures/$name (${content.length} chars)');
}

/// The buy grid's rows: (meal name, option descriptions).
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
    out.add((_text(cells[1]), options));
  }
  return out;
}

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

int? _credit(String html) {
  final m = RegExp('<label[^>]*id="lblCredit"[^>]*>(.*?)</label>', dotAll: true)
      .firstMatch(html);
  if (m == null) return null;
  final digits = m.group(1)!.replaceAll(RegExp(r'\D'), '');
  return digits.isEmpty ? null : int.tryParse(digits);
}

String? _textById(String html, String id) {
  final m = RegExp('id="[^"]*' + RegExp.escape(id) + r'"[^>]*>(.*?)<', dotAll: true)
      .firstMatch(html);
  final t = m?.group(1)?.replaceAll(RegExp(r'\s+'), ' ').trim();
  return (t == null || t.isEmpty) ? null : t;
}

String? _rawById(String html, String id) {
  final m = RegExp('id="[^"]*' + RegExp.escape(id) + r'"[^>]*>(.*?)</div>',
          dotAll: true)
      .firstMatch(html);
  return m?.group(1)?.replaceAll(RegExp(r'\s+'), ' ').trim();
}
