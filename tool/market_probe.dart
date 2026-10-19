/// Read-only probe: where does the Food Basket MARKETPLACE live?
///
/// The recon snapshot of `FoodBasketBuy.aspx` showed only three rows — the
/// student's OWN held meals (breakfast/lunch/dinner) — not other students'
/// released listings. If the marketplace is only reachable through a date
/// filter postback or through the sale page, the whole sniping feature is
/// pointed at the wrong endpoint.
///
/// This probe answers that question using only GETs and the read-only
/// "load food" postback (`btnFoodReload`), which loads *available* meals into
/// the sale dropdown. It never submits a reservation, purchase, or listing.
///
/// Usage: `dart run tool/market_probe.dart <studentId> <password>`
// Diagnostic probe: not shipped code. Regexes are built by
// concatenation deliberately, because interpolating a regex escape
// into a raw string reads worse than `+`.
// ignore_for_file: prefer_interpolation_to_compose_strings

library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bahonar_nut/adapter/captcha_solver.dart';

const _base = 'https://nut.uk.ac.ir/';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: dart run tool/market_probe.dart <studentId> <password>');
    exitCode = 2;
    return;
  }

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  final cookies = <String, String>{};

  try {
    // --- Log in ---
    final page = await _get(client, _base, cookies);
    final captchaBytes = await _getBytes(
      client,
      '${_base}UserControls/Captcha.ashx',
      cookies,
    );
    final solution = CaptchaSolver().solve(captchaBytes);
    if (solution.text == null) {
      stdout.writeln('captcha declined');
      return;
    }
    final login = await _post(client, _base, cookies, {
      '__VIEWSTATE': _input(page, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': _input(page, '__VIEWSTATEGENERATOR'),
      '__VIEWSTATEENCRYPTED': '',
      'txtUsername': args[0],
      'txtPassword': args[1],
      'txtCaptcha': solution.text!,
      'btnLogin': 'ورود سمت سرور ',
    });
    if (login.contains('txtUsernamePlain')) {
      stdout.writeln('LOGIN FAILED: ${_label(login, 'lblLoginError')}');
      return;
    }
    stdout.writeln('logged in (solver read ${solution.text})');

    // --- A. Basket buy page, as-is ---
    final buy = await _get(client, '${_base}FoodBasket/FoodBasketBuy.aspx', cookies);
    stdout.writeln('\nA. FoodBasketBuy.aspx (no filter)');
    _report('  grid rows', _gridRows(buy, 'grdFoodBasketReservation'));
    for (final row in _gridRows(buy, 'grdFoodBasketReservation').take(6)) {
      stdout.writeln('     $row');
    }
    stdout.writeln('   date field: ${_value(buy, 'cphMain_txtDate')}');
    stdout.writeln('   today: ${_label(buy, 'cphMain_lblTodayDate')}');

    // --- B. Basket buy page, with a future date filter ---
    // The page has txtDate + imgbtnGoToDate. Submitting the date is a
    // *read* filter (it only changes which rows are shown).
    for (final date in ['1405/08/02', '1405/08/09', '1405/08/16']) {
      final filtered = await _post(client, '${_base}FoodBasket/FoodBasketBuy.aspx',
          cookies, {
        '__VIEWSTATE': _input(buy, '__VIEWSTATE'),
        '__VIEWSTATEGENERATOR': _input(buy, '__VIEWSTATEGENERATOR'),
        '__EVENTTARGET': '',
        '__EVENTARGUMENT': '',
        'ctl00\$cphMain\$txtDate': date,
        'ctl00\$cphMain\$imgbtnGoToDate.x': '1',
        'ctl00\$cphMain\$imgbtnGoToDate.y': '1',
      });
      final rows = _gridRows(filtered, 'grdFoodBasketReservation');
      stdout.writeln('\nB. FoodBasketBuy.aspx filtered to $date -> ${rows.length} rows');
      for (final row in rows.take(6)) {
        stdout.writeln('     $row');
      }
    }

    // --- C. Basket sale page, and the read-only "load food" postback ---
    final sale = await _get(client, '${_base}FoodBasket/FoodBasketSale.aspx', cookies);
    stdout.writeln('\nC. FoodBasketSale.aspx');
    stdout.writeln('   reserve-type options: ${_options(sale, 'drpReserveType')}');
    stdout.writeln('   food-type options:    ${_options(sale, 'drpFoodType')}');
    stdout.writeln('   date field: ${_value(sale, 'cphMain_txtDate')}');

    final loaded = await _post(client, '${_base}FoodBasket/FoodBasketSale.aspx',
        cookies, {
      '__VIEWSTATE': _input(sale, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': _input(sale, '__VIEWSTATEGENERATOR'),
      '__EVENTTARGET': '',
      '__EVENTARGUMENT': '',
      'ctl00\$cphMain\$txtDate': '1405/08/02',
      'ctl00\$cphMain\$drpReserveType': '1',
      'ctl00\$cphMain\$drpFoodType': '2',
      'ctl00\$cphMain\$btnFoodReload': 'بارگذاری غذا',
    });
    stdout.writeln('   after btnFoodReload:');
    for (final id in ['drpFood', 'drpSelf', 'lblFoodType']) {
      final opts = _options(loaded, id);
      if (opts.isNotEmpty) stdout.writeln('     $id -> $opts');
    }
    final saleRows = _gridRows(loaded, 'grd');
    stdout.writeln('     grid rows: ${saleRows.length}');
    for (final row in saleRows.take(6)) {
      stdout.writeln('       $row');
    }

    // --- D. Any grid anywhere on the sale page ---
    for (final m in RegExp(r'<table[^>]*id="([^"]*)"[^>]*>')
        .allMatches(loaded)) {
      final id = m.group(1)!;
      final rows = _gridRows(loaded, id);
      if (rows.isNotEmpty) {
        stdout.writeln('   TABLE $id -> ${rows.length} rows');
        for (final row in rows.take(4)) {
          stdout.writeln('       $row');
        }
      }
    }
  } finally {
    client.close(force: true);
  }
}

void _report(String label, List<String> rows) => stdout.writeln('$label: ${rows.length}');

/// Rows of a grid, rendered as "meal | hall | food | price".
List<String> _gridRows(String html, String gridId) {
  final table = RegExp('<table[^>]*id="[^"]*' + RegExp.escape(gridId) +
          '[^"]*"[^>]*>(.*?)</table>',
      dotAll: true)
      .firstMatch(html);
  if (table == null) return const [];
  final rows = <String>[];
  for (final row in RegExp(r'<tr[^>]*>(.*?)</tr>', dotAll: true)
      .allMatches(table.group(1)!)) {
    final cells = RegExp(r'<td[^>]*>(.*?)</td>', dotAll: true)
        .allMatches(row.group(1)!)
        .map((m) => m.group(1)!)
        .toList();
    if (cells.isEmpty) continue;
    final meal = _text(cells[1]);
    final hall = _text(cells[2]);
    final food = _text(cells[3]);
    final price = cells.length > 6 ? _text(cells[6]) : '';
    if (meal.isEmpty && food.isEmpty) continue;
    rows.add('$meal | $hall | $food | $price');
  }
  return rows;
}

String _text(String cell) =>
    cell.replaceAll(RegExp(r'<[^>]+>'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

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
  final t = m?.group(1)?.replaceAll(RegExp(r'\s+'), ' ').trim();
  return (t == null || t.isEmpty) ? null : t;
}

/// Option values+texts of every select whose name contains [suffix].
List<String> _options(String html, String suffix) {
  final out = <String>[];
  for (final m in RegExp('<select[^>]*name="([^"]*' +
          RegExp.escape(suffix) +
          r')"[^>]*>(.*?)</select>',
          dotAll: true)
      .allMatches(html)) {
    for (final o in RegExp(r'<option[^>]*value="([^"]*)"[^>]*>(.*?)</option>',
            dotAll: true)
        .allMatches(m.group(2)!)) {
      out.add('${o.group(1)}=${_text(o.group(2)!)}');
    }
  }
  return out;
}

String _input(String html, String id) {
  final m = RegExp('id="' + RegExp.escape(id) + r'"[^>]*value="([^"]*)"')
      .firstMatch(html);
  return m?.group(1) ?? '';
}

Future<String> _get(
  HttpClient client,
  String url,
  Map<String, String> cookies,
) async {
  final req = await client.getUrl(Uri.parse(url));
  _headers(req, cookies);
  final resp = await req.close();
  final body = await resp.transform(utf8.decoder).join();
  _capture(resp, cookies);
  return body;
}

Future<Uint8List> _getBytes(
  HttpClient client,
  String url,
  Map<String, String> cookies,
) async {
  final req = await client.getUrl(Uri.parse(url));
  _headers(req, cookies);
  final resp = await req.close();
  final chunks = await resp.toList();
  _capture(resp, cookies);
  return Uint8List.fromList(chunks.expand((c) => c).toList());
}

Future<String> _post(
  HttpClient client,
  String url,
  Map<String, String> cookies,
  Map<String, String> body,
) async {
  final req = await client.postUrl(Uri.parse(url));
  req.followRedirects = false;
  _headers(req, cookies);
  req.headers.contentType = ContentType('application', 'x-www-form-urlencoded');
  req.write(body.entries
      .map((e) =>
          '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
      .join('&'));
  final resp = await req.close();
  final text = await resp.transform(utf8.decoder).join();
  _capture(resp, cookies);
  if (resp.statusCode == 302) {
    final loc = resp.headers.value(HttpHeaders.locationHeader);
    if (loc != null && !loc.contains('error')) {
      return _get(client, loc.startsWith('http') ? loc : '$_base$loc', cookies);
    }
  }
  return text;
}

void _headers(HttpClientRequest req, Map<String, String> cookies) {
  req.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0');
  req.headers.set(HttpHeaders.refererHeader, _base);
  if (cookies.isNotEmpty) {
    req.headers.set(
      HttpHeaders.cookieHeader,
      cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
    );
  }
}

void _capture(HttpClientResponse resp, Map<String, String> cookies) {
  for (final raw
      in resp.headers[HttpHeaders.setCookieHeader] ?? const <String>[]) {
    final pair = raw.split(';').first;
    final i = pair.indexOf('=');
    if (i > 0) {
      cookies[pair.substring(0, i).trim()] = pair.substring(i + 1).trim();
    }
  }
}
