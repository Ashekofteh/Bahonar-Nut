/// READ-ONLY probe: the Food Basket's semantics.
///
/// The product owner reports that a meal BOUGHT from the basket cannot be
/// cancelled or resold — unlike a weekly reservation, which can be released
/// (by unchecking the row) while the date is still editable. That claim
/// changes the risk profile of auto-buy, so it is worth checking directly
/// rather than assuming.
///
/// This probe answers three questions without buying or selling anything:
///   1. What does FoodBasketBuy.aspx actually list — the account's own meals,
///      other students' released meals, or both?
///   2. Does FoodBasketSale.aspx offer any way to WITHDRAW a listing?
///   3. Where does a basket purchase show up afterwards — the weekly
///      reservation grid, the transaction ledger, or neither?
///
/// Usage: `dart run tool/basket_semantics_probe.dart <studentId> <password>`
// Read-only diagnostic probe.
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

/// Every control that looks like it withdraws or removes something.
List<String> withdrawControls(String html) {
  final found = <String>[];
  for (final m in RegExp(r'<(input|button|a)[^>]*>', dotAll: true)
      .allMatches(html)) {
    final tag = m.group(0)!;
    final lower = tag.toLowerCase();
    if (!(lower.contains('cancel') ||
        lower.contains('delete') ||
        lower.contains('remove') ||
        lower.contains('withdraw') ||
        tag.contains('لغو') ||
        tag.contains('حذف') ||
        tag.contains('برداشتن'))) {
      continue;
    }
    found.add('  ${m.group(1)} name="${_attr(tag, 'name')}" '
        'id="${_attr(tag, 'id')}" value="${_attr(tag, 'value')}"');
  }
  return found;
}

/// The buy grid's rows, with everything that identifies them.
List<String> buyRows(String html) {
  final t = RegExp('<table[^>]*id="[^"]*grdFoodBasketReservation"[^>]*>(.*?)</table>',
          dotAll: true)
      .firstMatch(html);
  if (t == null) return const [];

  final out = <String>[];
  for (final m in RegExp(r'<tr[^>]*>(.*?)</tr>', dotAll: true)
      .allMatches(t.group(1)!)) {
    final raw = m.group(1)!;
    final cells = RegExp(r'<td[^>]*>(.*?)</td>', dotAll: true)
        .allMatches(raw)
        .map((c) => c.group(1)!)
        .toList();
    if (cells.length < 4) continue;

    final meal = _text(cells[1]);
    final hall = _selectValue(cells[2], 'drpSelf');
    final food = _selectValue(cells[3], 'drpFood');
    final options = _selectOptions(cells[3], 'drpFood');
    final amount = cells.length > 6 ? _text(cells[6]) : '';
    final status = cells.length > 7 ? _text(cells[7]) : '';
    final checked = raw.contains('checked="checked"');
    final disabled = RegExp(r'type="checkbox"[^>]*disabled')
        .hasMatch(raw.split('</td>').first);

    out.add('meal=$meal hall=$hall food="$food" amount=$amount '
        'status="$status" checked=$checked disabled=$disabled');
    for (final o in options) {
      out.add('    option $o');
    }
  }
  return out;
}

String _selectValue(String cell, String suffix) {
  final m = RegExp('<select[^>]*name="[^"]*' + RegExp.escape(suffix) +
          r'"[^>]*>(.*?)</select>',
          dotAll: true)
      .firstMatch(cell);
  if (m == null) return '-';
  final sel = RegExp(r'<option[^>]*value="([^"]*)"[^>]*selected', dotAll: true)
      .firstMatch(m.group(1)!);
  return sel?.group(1) ?? '-';
}

List<String> _selectOptions(String cell, String suffix) {
  final m = RegExp('<select[^>]*name="[^"]*' + RegExp.escape(suffix) +
          r'"[^>]*>(.*?)</select>',
          dotAll: true)
      .firstMatch(cell);
  if (m == null) return const [];
  return RegExp(r'<option[^>]*value="([^"]*)"[^>]*>(.*?)</option>', dotAll: true)
      .allMatches(m.group(1)!)
      .map((o) => '${o.group(1)}=${_text(o.group(2)!)}')
      .toList();
}

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run tool/basket_semantics_probe.dart <studentId> <password>');
    exitCode = 2;
    return;
  }
  final username = args[0];
  final password = args[1];

  captureDir = Directory('captures')..createSync(recursive: true);
  print('=== BASKET SEMANTICS PROBE ${DateTime.now().toIso8601String()} ===');

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
    print('login OK; credit: ${_label(login.body, 'lblCredit')}');

    // The account's own reservations, for comparison against the basket.
    final reservation =
        await transport.get(username, '/Reservation/Reservation.aspx');
    save('70_reservation_hub.html', reservation.body);
    print('\n--- the account\'s OWN weekly reservations ---');
    for (final line in _ownRows(reservation.body)) {
      print('  $line');
    }

    // ---------------------------------------------- THE BUY PAGE
    print('\n--- FoodBasketBuy.aspx (the BUY side) ---');
    final buy = await transport.get(username, '/FoodBasket/FoodBasketBuy.aspx');
    save('71_basket_buy.html', buy.body);
    print('date field: ${_value(buy.body, 'cphMain_txtDate')}');
    print('today: ${_textById(buy.body, 'cphMain_lblTodayDate')}');
    final rows = buyRows(buy.body);
    print('rows: ${rows.length}');
    for (final r in rows) {
      print('  $r');
    }

    final buyWithdraws = withdrawControls(buy.body);
    print('withdraw-like controls on the BUY page: '
        '${buyWithdraws.isEmpty ? "NONE" : ""}');
    for (final c in buyWithdraws) {
      print(c);
    }

    // ---------------------------------------------- THE SALE PAGE
    print('\n--- FoodBasketSale.aspx (the SELL side) ---');
    final sale = await transport.get(username, '/FoodBasket/FoodBasketSale.aspx');
    save('72_basket_sale.html', sale.body);
    print('date field: ${_value(sale.body, 'cphMain_txtDate')}');
    final saleWithdraws = withdrawControls(sale.body);
    print('withdraw-like controls on the SALE page: '
        '${saleWithdraws.isEmpty ? "NONE" : ""}');
    for (final c in saleWithdraws) {
      print(c);
    }
    print('all named controls on the sale page:');
    for (final m in RegExp(r'<(input|select)[^>]*name="([^"]+)"[^>]*>')
        .allMatches(sale.body)) {
      final tag = m.group(0)!;
      print('  ${m.group(1)} name="${m.group(2)!}" '
          'value="${_attr(tag, 'value')}" type="${_attr(tag, 'type')}"');
    }

    // ------------------------------- THE TRANSACTIONS, for the record
    print('\n--- transactions (transaction types seen) ---');
    final tx = await transport.get(username, '/MyCullinan/MyTransaction.aspx');
    save('73_transactions.html', tx.body);
    final types = <String>{};
    final t = RegExp('<table[^>]*id="[^"]*grdContent"[^>]*>(.*?)</table>',
            dotAll: true)
        .firstMatch(tx.body);
    for (final m in RegExp(r'<tr[^>]*>(.*?)</tr>', dotAll: true)
        .allMatches(t?.group(1) ?? '')) {
      final cells = RegExp(r'<td[^>]*>(.*?)</td>', dotAll: true)
          .allMatches(m.group(1)!)
          .map((c) => _text(c.group(1)!))
          .toList();
      if (cells.isNotEmpty && cells.first.isNotEmpty) {
        types.add(cells.first);
      }
    }
    print('  distinct transaction types: ${types.toList()..sort()}');
  } catch (e, st) {
    print('EXCEPTION: $e');
    print(st.toString().split('\n').take(8).join('\n'));
  } finally {
    transport.close();
  }
}

/// The account's own held meals, from the weekly reservation grid.
List<String> _ownRows(String html) {
  final out = <String>[];
  for (final entry in [
    'grdReservationBreakfast',
    'grdReservationLunch',
    'grdReservationDinner'
  ]) {
    final t = RegExp('<table[^>]*id="[^"]*' + entry + r'"[^>]*>(.*?)</table>',
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
      out.add('${entry.replaceAll("grdReservation", "")} '
          '${_text(cells[1])}  ${_text(cells[3])}');
    }
  }
  return out;
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

String? _textById(String html, String id) {
  final m = RegExp('id="[^"]*' + RegExp.escape(id) + r'"[^>]*>(.*?)<', dotAll: true)
      .firstMatch(html);
  final t = m?.group(1)?.replaceAll(RegExp(r'\s+'), ' ').trim();
  return (t == null || t.isEmpty) ? null : t;
}
