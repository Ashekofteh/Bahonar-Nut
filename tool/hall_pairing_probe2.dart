/// READ-ONLY probe (v2): does the buy page link a dish to a hall?
///
/// ## Why v1 was inconclusive
///
/// v1 posted only `__VIEWSTATE` + `__EVENTTARGET` + `txtDate` + the target
/// row's `drpSelf`. The buy page is a WebForms grid, and a post that omits the
/// rest of the form state is very likely to have been **ignored** — so
/// "the hall list did not change" proved nothing. It might simply have been
/// the same page back.
///
/// ## What v2 does differently
///
/// It posts the **complete form state** — every row's `drpSelf`, `drpFood`,
/// `drpFoodCount`, and the date filter — with the target row's `drpFood`
/// changed and the `drpFood` control named as the event target. That is what
/// a browser sends when the user changes the dish.
///
/// It then checks TWO things in the response:
///   * did the **selected dish** actually change? (proves the postback took)
///   * did the **hall list** change with it? (the actual question)
///
/// ## Why it is safe
///
/// The postback carries **no `btnSave`**, so it cannot purchase anything. It
/// is the same class of operation as the date-filter postback.
///
/// Usage: `dart run tool/hall_pairing_probe2.dart <studentId> <password>
// Diagnostic probe: stdout printing is the entire point.
// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings

library;

import 'dart:io';

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/transport/http_transport.dart';

const _base = 'https://nut.uk.ac.ir/';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run tool/hall_pairing_probe2.dart <studentId> <password>');
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

    final buy =
        (await transport.get(username, '/FoodBasket/FoodBasketBuy.aspx')).body;
    print('buy page date: ${_value(buy, "cphMain_txtDate")}');

    final rows = _rows(buy);
    for (final row in rows) {
      print('');
      print('=== row ${row.slot} ===');
      print('   halls:  ${row.halls.map((h) => '${h.value}=${h.text}').join(", ")}');
      print('   dishes: ${row.options.map((o) => "${o.value}=${o.text}").join(" | ")}');

      if (row.options.length < 2) {
        print('   (one dish only - nothing to compare)');
        continue;
      }

      for (final option in row.options) {
        final after = await _changeDish(transport, username, buy, row, option);
        if (after == null) {
          print('   dish ${option.value}: the postback FAILED to re-render');
          continue;
        }
        final dishChanged = after.selectedFood == option.value;
        final hallsBefore = row.halls.map((h) => '${h.value}=${h.text}').join(", ");
        final hallsAfter = after.halls.map((h) => '${h.value}=${h.text}').join(", ");
        print('   dish ${option.value} (${option.text}):');
        print('      postback took effect: $dishChanged '
            '(selected=${after.selectedFood})');
        print('      halls before: $hallsBefore');
        print('      halls after:  $hallsAfter');
        if (!dishChanged) {
          print('      => the postback did not change the dish; '
              'this row proves nothing');
        } else if (hallsAfter == hallsBefore) {
          print('      => the hall list is UNCHANGED by the dish: '
              'the two dropdowns are INDEPENDENT');
        } else {
          print('      => the hall list CHANGED with the dish: '
              'the two dropdowns are LINKED');
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

/// Posts the complete form state with the row's dish changed, and returns the
/// row as it comes back.
Future<_Row?> _changeDish(
  PortalTransport transport,
  String username,
  String html,
  _Row row,
  _Opt option,
) async {
  // The COMPLETE form state, with one field changed.
  final body = <String, String>{
    '__VIEWSTATE': _input(html, '__VIEWSTATE'),
    '__VIEWSTATEGENERATOR': _input(html, '__VIEWSTATEGENERATOR'),
    '__EVENTTARGET': row.foodName,
    '__EVENTARGUMENT': '',
    'ctl00\$cphMain\$txtDate': _value(html, 'cphMain_txtDate'),
  };

  for (final other in _rows(html)) {
    body[other.selfName] = other.hallValue;
    body[other.foodName] = other.selectedFood;
    body[other.countName] = other.countValue;
  }

  // The one field this post changes.
  body[row.foodName] = option.value;

  final response = await transport.post(
    username,
    '/FoodBasket/FoodBasketBuy.aspx',
    body: body,
  );

  for (final after in _rows(response.body)) {
    if (after.foodName == row.foodName) return after;
  }
  return null;
}

class _Opt {
  _Opt(this.value, this.text);

  final String value;
  final String text;
}

class _Row {
  _Row(this.slot, this.foodName, this.selfName, this.countName,
      this.hallValue, this.selectedFood, this.countValue, this.halls,
      this.options);

  final String slot;
  final String foodName;
  final String selfName;
  final String countName;
  final String hallValue;
  final String selectedFood;
  final String countValue;
  final List<_Opt> halls;
  final List<_Opt> options;
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

    final food = _select(raw, 'drpFood');
    final self = _select(raw, 'drpSelf');
    final count = _select(raw, 'drpFoodCount');
    if (food == null || self == null || count == null) continue;

    out.add(_Row(
      _text(cells[1]),
      food.name,
      self.name,
      count.name,
      self.selectedValue ?? '',
      food.selectedValue ?? '',
      count.selectedValue ?? '',
      self.options,
      food.options,
    ));
  }
  return out;
}

class _Sel {
  _Sel(this.name, this.selectedValue, this.options);

  final String name;
  final String? selectedValue;
  final List<_Opt> options;
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
