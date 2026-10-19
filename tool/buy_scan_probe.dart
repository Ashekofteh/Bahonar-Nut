/// READ-ONLY probe: find a buy page that lists two dishes AND two halls, then
/// test whether the two dropdowns are linked.
///
/// ## Why
///
/// The hall-priority feature ("Central first, Engineering second") is only
/// implementable if the app can tell which halls a given dish is offered in.
/// The buy grid's `drpFood` and `drpSelf` are independent selects, so the
/// question is whether the hall list is a function of the selected dish.
///
/// The live page for 1405/07/28 offers one dish per row, so the test needs a
/// richer page. This probe scans forward day by day for a row that offers two
/// or more dishes and two or more halls, and runs the pairing test there.
///
/// ## The test
///
/// Post the COMPLETE form state with the row's `drpFood` changed, using the
/// `drpFood` control as the event target — what a browser sends. Then check
/// whether the hall list came back different.
///
/// A postback that does not change the selected dish proves nothing, so the
/// probe reports that case explicitly rather than counting it as "unchanged".
///
/// ## Why it is safe
///
/// No `btnSave` in any post, so nothing can be purchased, reserved, listed or
/// cancelled. Only GETs, the date filter, and dropdown postbacks.
///
/// Usage: `dart run tool/buy_scan_probe.dart <studentId> <password>
// Diagnostic probe: stdout printing is the entire point.
// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings

library;

import 'dart:io';

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/transport/http_transport.dart';

const _base = 'https://nut.uk.ac.ir/';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run tool/buy_scan_probe.dart <studentId> <password>');
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

    // --- scan forward for a rich row ---
    final dates = _candidateDates();
    for (final date in dates) {
      final filtered = await _setDate(transport, username, buy, date);
      if (_value(filtered, 'cphMain_txtDate') != date) {
        print('$date: the date filter did not take (field is '
            '${_value(filtered, "cphMain_txtDate")})');
        continue;
      }

      for (final row in _rows(filtered)) {
        final dishes = row.options.where((o) => o.value != '-1').toList();
        final halls = row.halls.where((h) => h.value != '-1').toList();

        print('$date  ${row.slot}: ${dishes.length} dish(es), '
            '${halls.length} hall(s)');

        if (dishes.length < 2 || halls.length < 2) continue;

        print('   >>> RICH ROW FOUND: ${row.slot} on $date');
        print('   halls:  ${row.halls.map((h) => '${h.value}=${h.text}').join(", ")}');
        print('   dishes: ${dishes.map((o) => "${o.value}=${o.text}").join(" | ")}');
        await _testPairing(transport, username, filtered, row);
        return;
      }
    }

    print('\nno row with two dishes and two halls was found in '
        '${dates.length} days');
  } catch (e, st) {
    print('EXCEPTION: $e');
    print(st.toString().split('\n').take(8).join('\n'));
  } finally {
    transport.close();
  }
}

/// Runs the pairing test on a row that offers several dishes and halls.
Future<void> _testPairing(
  PortalTransport transport,
  String username,
  String html,
  _Row row,
) async {
  final hallsBefore = row.halls.map((h) => '${h.value}=${h.text}').join(', ');

  for (final option in row.options.where((o) => o.value != '-1')) {
    final after = await _changeDish(transport, username, html, row, option);
    if (after == null) {
      print('   dish ${option.value}: the postback did not re-render the row');
      continue;
    }

    final took = after.selectedFood == option.value;
    final hallsAfter = after.halls.map((h) => '${h.value}=${h.text}').join(', ');

    print('');
    print('   dish ${option.value} = ${option.text}');
    print('      postback took effect: $took '
        '(selected=${after.selectedFood})');
    print('      halls before: $hallsBefore');
    print('      halls after:  $hallsAfter');
    if (!took) {
      print('      => INCONCLUSIVE: the dish did not change');
    } else if (hallsAfter == hallsBefore) {
      print('      => INDEPENDENT: the hall list ignores the dish');
    } else {
      print('      => LINKED: the hall list follows the dish');
    }
  }
}

/// Posts the complete form state with the row's dish changed.
Future<_Row?> _changeDish(
  PortalTransport transport,
  String username,
  String html,
  _Row row,
  _Opt option,
) async {
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

/// The next fourteen days, as the portal's Jalali dates.
List<String> _candidateDates() {
  // Anchor on the portal's own "today" so the scan starts where the portal is.
  final now = DateTime.now().toUtc().add(const Duration(hours: 3, minutes: 30));
  final out = <String>[];
  for (var i = 0; i < 14; i++) {
    final day = now.add(Duration(days: i));
    out.add(_jalali(day));
  }
  return out;
}

/// A Jalali date string, via the app's own verified conversion.
String _jalali(DateTime date) {
  // The probe is standalone, so it cannot import the app's converter; the
  // conversion is inlined from the standard algorithm and cross-checked by
  // comparing the portal's own date field.
  const gDays = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334];
  final gy = date.year;
  final gm = date.month;
  final gd = date.day;
  final gy2 = gm > 2 ? gy + 1 : gy;
  var days = 355666 +
      (365 * gy) +
      ((gy2 + 3) ~/ 4) -
      ((gy2 + 99) ~/ 100) +
      ((gy2 + 399) ~/ 400) +
      gd +
      gDays[gm - 1];
  var jy = -1595 + (33 * (days ~/ 12053));
  days %= 12053;
  jy += 4 * (days ~/ 1461);
  days %= 1461;
  if (days > 365) {
    jy += (days - 1) ~/ 365;
    days = (days - 1) % 365;
  }
  int jm;
  int jd;
  if (days < 186) {
    jm = 1 + (days ~/ 31);
    jd = 1 + (days % 31);
  } else {
    jm = 7 + ((days - 186) ~/ 30);
    jd = 1 + ((days - 186) % 30);
  }
  return '${jy.toString().padLeft(4, '0')}/'
      '${jm.toString().padLeft(2, '0')}/'
      '${jd.toString().padLeft(2, '0')}';
}

/// The buy page's own date filter.
Future<String> _setDate(
  PortalTransport transport,
  String username,
  String html,
  String date,
) async {
  final response = await transport.post(
    username,
    '/FoodBasket/FoodBasketBuy.aspx',
    body: {
      '__VIEWSTATE': _input(html, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': _input(html, '__VIEWSTATEGENERATOR'),
      '__EVENTTARGET': '',
      '__EVENTARGUMENT': '',
      'ctl00\$cphMain\$txtDate': date,
      'ctl00\$cphMain\$imgbtnGoToDate.x': '1',
      'ctl00\$cphMain\$imgbtnGoToDate.y': '1',
    },
  );
  return response.body;
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
