/// Live read-only probe of session persistence behaviour.
///
/// Answers the question the whole login architecture rests on: **does a stored
/// session survive, or does every run need a fresh login?** If it survives, the
/// CAPTCHA solver is a fallback and the app is quiet; if not, silent re-login via
/// the solver is the normal path. Either way it works — but knowing which tells
/// us how much request traffic to expect per day.
///
/// READ-ONLY. No reservation, purchase, cancellation or top-up is performed.
///
/// Usage:
///   `dart run tool/session_probe.dart <studentId> <password>`
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bahonar_nut/adapter/captcha_solver.dart';

const _base = 'https://nut.uk.ac.ir/';
const _cookieFile = 'recon/session_probe_cookies.json';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: dart run tool/session_probe.dart <studentId> <password>');
    exitCode = 2;
    return;
  }
  final username = args[0];
  final password = args[1];

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);

  try {
    // --- Test 1: does a previously stored session still work? ---
    final stored = _loadCookies();
    if (stored.isNotEmpty) {
      stdout.writeln('1. found a stored session (${stored.length} cookies)');
      final reused = await _canReadAuthenticatedPage(client, stored);
      if (reused) {
        stdout.writeln('   RESULT: stored session STILL VALID - no login needed');
        stdout.writeln('           -> the common path is reuse; solver is a fallback');
        return;
      }
      stdout.writeln('   RESULT: stored session EXPIRED - re-login required');
      stdout.writeln('           -> silent re-login via the solver is the normal path');
    } else {
      stdout.writeln('1. no stored session yet (first run)');
    }

    // --- Test 2: perform a login and persist the session ---
    final cookies = <String, String>{};
    final page = await _get(client, _base, cookies);
    final viewState = _input(page, '__VIEWSTATE');
    final viewStateGen = _input(page, '__VIEWSTATEGENERATOR');

    final captchaBytes = await _getBytes(
      client,
      '${_base}UserControls/Captcha.ashx',
      cookies,
    );
    final solution = CaptchaSolver().solve(captchaBytes);
    stdout.writeln('2. captcha solved: ${solution.text ?? "<declined>"} '
        '(confidence ${solution.confidence.toStringAsFixed(1)})');

    if (solution.text == null) {
      stdout.writeln('   solver declined; nothing further to do');
      return;
    }

    final loginPage = await _post(client, _base, cookies, {
      '__VIEWSTATE': viewState,
      '__VIEWSTATEGENERATOR': viewStateGen,
      '__VIEWSTATEENCRYPTED': '',
      'txtUsername': username,
      'txtPassword': password,
      'txtCaptcha': solution.text!,
      'btnLogin': 'ورود سمت سرور ',
    });

    if (loginPage.contains('txtUsernamePlain')) {
      stdout.writeln('3. LOGIN FAILED: ${_label(loginPage, 'lblLoginError')}');
      return;
    }
    stdout.writeln('3. login OK, session established');

    // --- Test 3: confirm the session reads an authenticated page ---
    final hub = await _get(
      client,
      '${_base}Reservation/Reservation.aspx',
      cookies,
    );
    final credit = _label(hub, 'lblCredit') ?? '<unknown>';
    stdout.writeln('4. authenticated read OK, credit = $credit');

    // --- Test 4: discover what the session cookie's lifetime looks like ---
    stdout.writeln('5. session cookies observed:');
    for (final entry in cookies.entries) {
      stdout.writeln('     ${entry.key} = ${_preview(entry.value)}');
    }

    _saveCookies(cookies);
    stdout.writeln('6. session persisted to $_cookieFile');
    stdout.writeln('   run this probe again to test whether it survives');
  } finally {
    client.close(force: true);
  }
}

/// True when the stored cookies can read an authenticated page.
Future<bool> _canReadAuthenticatedPage(
  HttpClient client,
  Map<String, String> cookies,
) async {
  try {
    final html = await _get(
      client,
      '${_base}Reservation/Reservation.aspx',
      Map.of(cookies),
    );
    // A bounced request returns the login form instead of the hub.
    return !html.contains('txtUsernamePlain');
  } catch (_) {
    return false;
  }
}

String _preview(String value) =>
    value.length <= 12 ? value : '${value.substring(0, 12)}...';

Map<String, String> _loadCookies() {
  final file = File(_cookieFile);
  if (!file.existsSync()) return {};
  try {
    final decoded = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    return decoded.map((k, v) => MapEntry(k, v.toString()));
  } catch (_) {
    return {};
  }
}

void _saveCookies(Map<String, String> cookies) {
  File(_cookieFile).writeAsStringSync(jsonEncode(cookies));
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
  // The login POST answers with a 302 to the hub; follow it explicitly so a
  // success is distinguishable from a rejection.
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
    final location = resp.headers.value(HttpHeaders.locationHeader);
    if (location != null && !location.contains('error')) {
      final target = location.startsWith('http') ? location : '$_base$location';
      return _get(client, target, cookies);
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
  for (final raw in resp.headers[HttpHeaders.setCookieHeader] ?? const <String>[]) {
    final pair = raw.split(';').first;
    final idx = pair.indexOf('=');
    if (idx > 0) {
      cookies[pair.substring(0, idx).trim()] = pair.substring(idx + 1).trim();
    }
  }
}

String _input(String html, String id) {
  final re = RegExp('id="${RegExp.escape(id)}"[^>]*value="([^"]*)"');
  return re.firstMatch(html)?.group(1) ?? '';
}

String? _label(String html, String id) {
  final re = RegExp('<label[^>]*id="${RegExp.escape(id)}"[^>]*>(.*?)</label>',
      dotAll: true);
  final text = re.firstMatch(html)?.group(1)?.replaceAll(RegExp(r'\s+'), ' ').trim();
  return (text == null || text.isEmpty) ? null : text;
}