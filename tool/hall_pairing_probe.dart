/// READ-ONLY probe: does the buy page pair a dish with a hall?
///
/// ## The question
///
/// The buy grid's `drpFood` (which dish) and `drpSelf` (which hall) are two
/// INDEPENDENT dropdowns on the same row. From a static capture we cannot tell
/// whether:
///
///   (a) the two are linked — the hall list is the set of halls offering the
///       selected dish, so choosing a dish filters the halls; or
///   (b) they are independent — the hall list is the set of halls serving that
///       slot that day, and every (hall, dish) combination is purchasable.
///
/// The distinction decides whether the hunt's **hall priority** can work at
/// all. Under (a) the app must select the dish first and read the hall list
/// back; under (b) it can send any pair.
///
/// ## Why it is safe
///
/// The `drpFood` control carries an `onchange` that fires a `__doPostBack`.
/// That postback only re-renders the form; it carries **no `btnSave`**, so it
/// cannot purchase anything. This is the same class of operation as the date
/// filter postback, which the recon already used safely.
///
/// Nothing is bought, listed, reserved or cancelled. The probe only ever GETs
/// the buy page and posts a dropdown change.
///
/// Usage: `dart run tool/hall_pairing_probe.dart <studentId> <password>
// Diagnostic probe: stdout printing is the entire point.
// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings

library;

import 'dart:io';

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/transport/http_transport.dart';

const _base = 'https://nut.uk.ac.ir/';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run tool/hall_pairing_probe.dart <studentId> <password>');
    exitCode = 2;
    return;
  }
  final username = args[0];
  final password = args[1];

  final transport = PortalTransport(baseUri: Uri.parse(_base));

  try {
    // --- login (the full three-step sequence) ---
    final page = await transport.get(username, '/');
    final captcha = await transport.getBytes(username, '/UserControls/Captcha.ashx');
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

    // --- the buy page, unfiltered (today) ---
    final buy = await transport.get(username, '/FoodBasket/FoodBasketBuy.aspx');
    final date = _value(buy.body, 'cphMain_txtDate');
    print('\nbuy page date: $date');

    _report('as loaded', buy.body);

    // --- for each row, change the DISH and see whether the HALL list moves ---
    for (final row in _rows(buy.body)) {
      if (row.options.isEmpty) continue;
      for (final option in row.options) {
        await _probeDishChange(transport, username, buy.body, row, option);
      }
    }
  } catch (e, st) {
    print('EXCEPTION: $e');
    print(st.toString().split('\n').take(8).join('\n'));
  } finally {
    transport.close();
  }
}

/// Re-renders the buy page with a different dish selected on the row, and
/// reports the hall list that comes back.
Future<void> _probeDishChange(
  PortalTransport transport,
  String username,
  String html,
  _Row row,
  String optionId,
) async {
  final body = <String, String>{
    '__VIEWSTATE': _input(html, '__VIEWSTATE'),
    '__VIEWSTATEGENERATOR': _input(html, '__VIEWSTATEGENERATOR'),
    '__EVENTTARGET': row.foodName,
    '__EVENTARGUMENT': '',
    // The date filter must travel with the postback, or the page would reset
    // to today and the comparison would be against the wrong date.
    'ctl00\$cphMain\$txtDate': _value(html, 'cphMain_txtDate'),
  };

  // The hall the row currently has, so the post carries the complete state.
  body[row.selfName] = row.hallValue;

  try {
    final response = await transport.post(
      username,
      '/FoodBasket/FoodBasketBuy.aspx',
      body: body,
    );
    final after = _rowFor(response.body, row.foodName);
    final hallsBefore = row.halls.map((h) => '${h.value}=${h.text}').join(', ');
    final hallsAfter = after == null
        ? '<row gone>'
        : after.halls.map((h) => '${h.value}=${h.text}').join(', ');
    final moved = after != null && hallsAfter != hallsBefore;

    print('');
    print('row ${row.slot} / dish $optionId (${_dishText(row, optionId)})');
    print('   halls before: $hallsBefore');
    print('   halls after:  $hallsAfter');
    print('   => ${moved ? 'THE HALL LIST CHANGES with the dish' : 'the hall list is unchanged'}');
  } catch (e) {
    print('row ${row.slot} / dish $optionId -> EXCEPTION $e');
  }
}

void _report(String label, String html) {
  print('\n=== $label ===');
  for (final row in _rows(html)) {
    print('  ${row.slot}:');
    print('     halls:  ${row.halls.map((h) => '${h.value}=${h.text}').join(', ')}');
    print('     dishes: ${row.options.map((o) => '$o=${_dishText(row, o)}').join(' | ')}');
  }
}

String _dishText(_Row row, String optionId) {
  for (final option in row.optionTexts) {
    if (option.value == optionId) return option.text;
  }
  return '?';
}

/// One row of the buy grid.
class _Row {
  _Row(this.slot, this.foodName, this.selfName, this.hallValue, this.halls,
      this.options, this.optionTexts);

  final String slot;

  /// The `drpFood` control's name — the postback event target.
  final String foodName;

  /// The `drpSelf` control's name.
  final String selfName;

  /// The row's currently selected hall.
  final String hallValue;

  final List<_Opt> halls;
  final List<String> options;
  final List<_Opt> optionTexts;
}

List<_Row> _rows(String html) {
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

    final slot = _text(cells[1]);
    final food = _select(raw, 'drpFood');
    final self = _select(raw, 'drpSelf');
    if (food == null || self == null) continue;

    out.add(_Row(
      slot,
      food.name,
      self.name,
      self.selectedValue ?? '',
      self.options,
      food.options.map((o) => o.value).toList(),
      food.options,
    ));
  }
  return out;
}

/// The row whose `drpFood` control has the given name.
_Row? _rowFor(String html, String foodName) {
  for (final row in _rows(html)) {
    if (row.foodName == foodName) return row;
  }
  return null;
}

class _Sel {
  _Sel(this.name, this.selectedValue, this.options);

  final String name;
  final String? selectedValue;
  final List<_Opt> options;
}

/// A dropdown option: its value and its rendered text.
class _Opt {
  _Opt(this.value, this.text);

  final String value;
  final String text;

  @override
  String toString() => '$value=$text';
}

_Sel? _select(String html, String suffix) {
  final m = RegExp('<select[^>]*name="([^"]*' + RegExp.escape(suffix) +
          r')"[^>]*>(.*?)</select>',
          dotAll: true)
      .firstMatch(html);
  if (m == null) return null;

  final options = <_Opt>[];
  String? selected;
  for (final o in RegExp(r'<option([^>]*)>(.*?)</option>', dotAll: true)
      .allMatches(m.group(2)!)) {
    final attrs = o.group(1)!;
    final value = RegExp('value="([^"]*)"').firstMatch(attrs)?.group(1) ??
        _text(o.group(2)!);
    options.add(_Opt(value, _text(o.group(2)!)));
    if (selected == null && attrs.contains('selected')) selected = value;
  }
  return _Sel(m.group(1)!, selected, options);
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
