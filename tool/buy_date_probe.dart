/// READ-ONLY probe: what date does the buy page actually show, and what are its
/// rows?
///
/// ## Why
///
/// A live run showed the buy page's `txtDate` reading `1405/07/28` while the
/// breakfast row carried option `62798` — an id far from the `62737` that the
/// weekly reservation grid uses for that same date and dish. Menu option ids
/// increase with the date, so the rows may not belong to the date the field
/// claims.
///
/// That distinction is decisive for the hunt: if the buy page's rows are for a
/// different date than the one the hunt targets, the engine would claim
/// listings for the wrong day — and a basket purchase is irreversible.
///
/// So this probe compares, for the SAME date:
///   * the buy page's rows (after applying the date filter), and
///   * the weekly reservation grid's rows.
///
/// If the option ids agree, the buy page is filtered correctly. If they do not,
/// the filter is not applied, or the buy page lists something else entirely
/// (released meals rather than the official menu).
///
/// ## Why it is safe
///
/// Only GETs and the page's own date-filter postback. No `btnSave`, so
/// nothing is purchased, reserved, listed or cancelled.
///
/// Usage: `dart run tool/buy_date_probe.dart <studentId> <password>
// Diagnostic probe: stdout printing is the entire point.
// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings

library;

import 'dart:io';

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/transport/http_transport.dart';

const _base = 'https://nut.uk.ac.ir/';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run tool/buy_date_probe.dart <studentId> <password>');
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

    // --- the weekly grid, for the dates the buy page will be compared to ---
    final weekly =
        await transport.get(username, '/Reservation/Reservation.aspx');
    print('\n=== the WEEKLY grid ===');
    print('  page date: ${_label(weekly.body, "lblTodayDate")}');
    for (final grid in [
      'grdReservationBreakfast',
      'grdReservationLunch',
      'grdReservationDinner',
    ]) {
      for (final row in _weeklyRows(weekly.body, grid)) {
        print('  ${_slotOf(grid).padRight(10)} ${row.date.padRight(11)} '
            'foods=${row.foods.join(",")} halls=${row.halls.join(",")} '
            'checked=${row.checked} amount=${row.amount}');
      }
    }

    // --- the buy page, unfiltered ---
    final buy = await transport.get(username, '/FoodBasket/FoodBasketBuy.aspx');
    print('\n=== the BUY page, unfiltered ===');
    print('  txtDate:      ${_value(buy.body, "cphMain_txtDate")}');
    print('  lblTodayDate: ${_label(buy.body, "lblTodayDate")}');
    _dumpBuy(buy.body);

    // --- the buy page, filtered to a date, and compared ---
    for (final date in [
      _value(buy.body, 'cphMain_txtDate'),
      '1405/07/28',
      '1405/08/02',
    ]) {
      final filtered = await _setDate(transport, username, buy.body, date);
      print('\n=== the BUY page, filtered to $date ===');
      print('  txtDate:      ${_value(filtered.body, "cphMain_txtDate")}');
      print('  lblTodayDate: ${_label(filtered.body, "lblTodayDate")}');
      _dumpBuy(filtered.body);
    }
  } catch (e, st) {
    print('EXCEPTION: $e');
    print(st.toString().split('\n').take(8).join('\n'));
  } finally {
    transport.close();
  }
}

void _dumpBuy(String html) {
  for (final row in _buyRows(html)) {
    print('  ${row.slot.padRight(10)} foods=${row.foods.join(",")} '
        'halls=${row.halls.join(",")} checked=${row.checked} '
        'disabled=${row.disabled} amount=${row.amount}');
  }
}

/// Applies the buy page's date filter. A read-only postback.
Future<TransportResponse> _setDate(
  PortalTransport transport,
  String username,
  String html,
  String date,
) =>
    transport.post(username, '/FoodBasket/FoodBasketBuy.aspx', body: {
      '__VIEWSTATE': _input(html, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': _input(html, '__VIEWSTATEGENERATOR'),
      '__EVENTTARGET': '',
      '__EVENTARGUMENT': '',
      'ctl00\$cphMain\$txtDate': date,
      'ctl00\$cphMain\$imgbtnGoToDate.x': '1',
      'ctl00\$cphMain\$imgbtnGoToDate.y': '1',
    });

String _slotOf(String grid) => switch (grid) {
      'grdReservationBreakfast' => 'صبحانه',
      'grdReservationLunch' => 'ناهار',
      _ => 'شام',
    };

class _Row {
  _Row(this.slot, this.date, this.foods, this.halls, this.checked,
      this.disabled, this.amount);

  final String slot;
  final String date;
  final List<String> foods;
  final List<String> halls;
  final bool checked;
  final bool disabled;
  final String amount;
}

List<_Row> _weeklyRows(String html, String grid) {
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
      tag.contains('disabled'),
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
      tag.contains('disabled'),
      cells.length > 6 ? _text(cells[6]) : '',
    ));
  }
  return out;
}

/// The values of a dropdown's options, in order.
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
