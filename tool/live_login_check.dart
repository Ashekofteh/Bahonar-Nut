/// Live read-only probe: log in to the portal using only the on-device solver,
/// then read balance and basket inventory.
///
/// READ-ONLY. This script performs no reservation, purchase, cancellation, or
/// top-up. Those write paths are deliberately absent.
///
/// Usage: `dart run tool/live_login_check.dart <studentId> <password>`
///
/// The credentials are taken from argv and never written to disk or logged.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bahonar_nut/adapter/captcha_solver.dart';

const _base = 'https://nut.uk.ac.ir/';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: dart run tool/live_login_check.dart <studentId> <password>');
    exitCode = 2;
    return;
  }
  final username = args[0];
  final password = args[1];

  // Certificate validation is left at its secure default. The portal's cert is
  // a valid wildcard (CN=*.uk.ac.ir, Certum) and validates cleanly; spec §8
  // forbids disabling validation, and there is no reason to here.
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20);
  final cookies = <String, String>{};

  try {
    // --- Step 1: GET the login page (establishes ASP.NET session) ---
    final page = await _get(client, _base, cookies);
    final viewState = _extractInput(page, '__VIEWSTATE');
    final viewStateGen = _extractInput(page, '__VIEWSTATEGENERATOR');
    stdout.writeln('1. login page fetched (${page.length} bytes)');

    // --- Step 2: GET the CAPTCHA in the SAME session ---
    // The answer binds to the session at fetch time, so this must immediately
    // precede the POST with no page re-fetch in between.
    final captchaBytes = await _getBytes(
      client,
      '${_base}UserControls/Captcha.ashx',
      cookies,
    );
    stdout.writeln('2. captcha fetched (${captchaBytes.length} bytes)');

    // Debug aid: keep the last challenge image so a failed solve can be
    // inspected. Overwritten each run; never contains credentials.
    File('recon/last_live_captcha.gif').writeAsBytesSync(captchaBytes);

    // --- Step 3: solve it locally ---
    final solver = CaptchaSolver();
    final solution = solver.solve(captchaBytes);
    stdout.writeln(
      '3. solved: ${solution.text ?? "<declined>"} '
      '(confidence ${solution.confidence.toStringAsFixed(3)})',
    );

    if (solution.text == null) {
      stdout.writeln('   solver declined; would fall back to asking the user');
      return;
    }

    // --- Step 4: POST the login ---
    final body = {
      '__VIEWSTATE': viewState,
      '__VIEWSTATEGENERATOR': viewStateGen,
      '__VIEWSTATEENCRYPTED': '',
      'txtUsername': username,
      'txtPassword': password,
      'txtCaptcha': solution.text!,
      'btnLogin': 'ورود سمت سرور ',
    };

    final loginResp = await _post(client, _base, cookies, body);
    final isLoginPage = loginResp.contains('txtUsernamePlain');
    final error = _extractLabel(loginResp, 'lblLoginError');

    if (isLoginPage || error != null) {
      stdout.writeln('4. LOGIN FAILED: ${error ?? "still on login page"}');
      return;
    }
    stdout.writeln('4. LOGIN OK (redirected away from the login page)');

    // --- Step 5: read-only verification ---
    final reservationPage = await _get(
      client,
      '${_base}Reservation/Reservation.aspx',
      cookies,
    );
    stdout.writeln('5. reservation hub: ${reservationPage.length} bytes');
    stdout.writeln('   credit: ${_extractLabel(reservationPage, 'lblCredit')}');

    final basket = await _get(
      client,
      '${_base}FoodBasket/FoodBasketBuy.aspx',
      cookies,
    );
    stdout.writeln('6. basket page: ${basket.length} bytes');

    final rows = _parseBasketRows(basket);
    stdout.writeln('   basket listings found: ${rows.length}');
    for (final row in rows.take(5)) {
      stdout.writeln('     - $row');
    }
  } finally {
    client.close(force: true);
  }
}

Future<String> _get(HttpClient client, String url, Map<String, String> cookies) async {
  final req = await client.getUrl(Uri.parse(url));
  _applyHeaders(req, cookies);
  final resp = await req.close();
  final body = await resp.transform(utf8.decoder).join();
  _captureCookies(resp, cookies);
  return body;
}

Future<Uint8List> _getBytes(
  HttpClient client,
  String url,
  Map<String, String> cookies,
) async {
  final req = await client.getUrl(Uri.parse(url));
  _applyHeaders(req, cookies);
  final resp = await req.close();
  final chunks = await resp.toList();
  _captureCookies(resp, cookies);
  return Uint8List.fromList(chunks.expand((c) => c).toList());
}

Future<String> _post(
  HttpClient client,
  String url,
  Map<String, String> cookies,
  Map<String, String> body,
) async {
  final req = await client.postUrl(Uri.parse(url));
  // Do not let Dart transparently follow the post-login redirect: we want to
  // see the raw response so a failure is distinguishable from a success.
  req.followRedirects = false;
  _applyHeaders(req, cookies);
  req.headers.contentType = ContentType('application', 'x-www-form-urlencoded');
  req.write(body.entries
      .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
      .join('&'));
  final resp = await req.close();
  final text = await resp.transform(utf8.decoder).join();
  _captureCookies(resp, cookies);
  stdout.writeln('   [debug] POST status=${resp.statusCode} '
      'location=${resp.headers.value(HttpHeaders.locationHeader)} '
      'len=${text.length}');
  if (resp.statusCode == 302) {
    final location = resp.headers.value(HttpHeaders.locationHeader);
    if (location != null && !location.contains('error')) {
      final target = location.startsWith('http') ? location : '$_base$location';
      return _get(client, target, cookies);
    }
  }
  return text;
}

void _applyHeaders(HttpClientRequest req, Map<String, String> cookies) {
  req.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0');
  req.headers.set(HttpHeaders.refererHeader, _base);
  if (cookies.isNotEmpty) {
    req.headers.set(
      HttpHeaders.cookieHeader,
      cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
    );
  }
}

void _captureCookies(HttpClientResponse resp, Map<String, String> cookies) {
  for (final raw in resp.headers[HttpHeaders.setCookieHeader] ?? const <String>[]) {
    final pair = raw.split(';').first;
    final idx = pair.indexOf('=');
    if (idx > 0) cookies[pair.substring(0, idx).trim()] = pair.substring(idx + 1).trim();
  }
}

String _extractInput(String html, String id) {
  final re = RegExp('id="${RegExp.escape(id)}"[^>]*value="([^"]*)"');
  final m = re.firstMatch(html);
  return m?.group(1) ?? '';
}

String? _extractLabel(String html, String id) {
  final re = RegExp('<label[^>]*id="${RegExp.escape(id)}"[^>]*>(.*?)</label>',
      dotAll: true);
  final m = re.firstMatch(html);
  final text = m?.group(1)?.replaceAll(RegExp(r'\s+'), ' ').trim();
  return (text == null || text.isEmpty) ? null : text;
}

/// Extracts basket grid rows as "meal / hall / food / price" strings.
List<String> _parseBasketRows(String html) {
  final rows = <String>[];
  final rowRe = RegExp(r'<tr[^>]*>(.*?)</tr>', dotAll: true);
  for (final match in rowRe.allMatches(html)) {
    final row = match.group(1)!;
    if (!row.contains('lblFoodType')) continue;
    final meal = _span(row, 'lblFoodType');
    final amount = _span(row, 'lblBuyAmount');
    final food = RegExp(r'<option[^>]*>([^<]+)</option>').firstMatch(row)?.group(1);
    if (meal != null) {
      rows.add('$meal / ${food?.trim() ?? "-"} / $amount');
    }
  }
  return rows;
}

String? _span(String row, String prefix) {
  final re = RegExp('id="[^"]*${RegExp.escape(prefix)}[^"]*"[^>]*>([^<]*)<');
  final m = re.firstMatch(row);
  return m?.group(1)?.trim();
}