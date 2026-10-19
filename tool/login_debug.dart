/// Diagnose the login POST: compare the working probe's request with the
/// adapter's, byte for byte, and try variants until one succeeds.
///
/// READ-ONLY in effect: a login attempt is not a state-changing action on the
/// portal beyond establishing a session, and no meal is touched.
///
/// Usage: `dart run tool/login_debug.dart <studentId> <password>`
// Diagnostic CLI tool: stdout printing is the entire point.
// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings

library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bahonar_nut/adapter/captcha_solver.dart';

const _base = 'https://nut.uk.ac.ir/';

Future<void> main(List<String> args) async {
  final username = args[0];
  final password = args[1];

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    // --- Variant A: exactly the working probe's order ---
    print('=== VARIANT A: page, captcha, POST (probe order) ===');
    final cookiesA = <String, String>{};
    final pageA = await _get(client, _base, cookiesA);
    final vsA = _input(pageA, '__VIEWSTATE');
    final vsgA = _input(pageA, '__VIEWSTATEGENERATOR');
    print('page bytes: ${pageA.length}');
    print('viewstate len: ${vsA.length}, generator: $vsgA');
    print('cookies after page: ${cookiesA.keys.toList()}');

    final capA = await _getBytes(client, '${_base}UserControls/Captcha.ashx', cookiesA);
    print('cookies after captcha: ${cookiesA.keys.toList()}');
    print('captcha bytes: ${capA.length}');
    final solA = CaptchaSolver().solve(capA);
    print('solved: ${solA.text}');

    final respA = await _post(client, _base, cookiesA, {
      '__VIEWSTATE': vsA,
      '__VIEWSTATEGENERATOR': vsgA,
      '__VIEWSTATEENCRYPTED': '',
      'txtUsername': username,
      'txtPassword': password,
      'txtCaptcha': solA.text!,
      'btnLogin': 'ورود سمت سرور ',
    });
    print('POST A status=$respA status, isLoginPage=${respA.contains('txtUsernamePlain')}');
    print('  error label: ${_label(respA, 'lblLoginError')}');

    // --- Variant B: post WITHOUT the captcha field, to see if the error differs ---
    print('');
    print('=== VARIANT B: same but captcha field omitted ===');
    final cookiesB = <String, String>{};
    final pageB = await _get(client, _base, cookiesB);
    final capB = await _getBytes(client, '${_base}UserControls/Captcha.ashx', cookiesB);
    final solB = CaptchaSolver().solve(capB);
    print('solved: ${solB.text}');
    final respB = await _post(client, _base, cookiesB, {
      '__VIEWSTATE': _input(pageB, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': _input(pageB, '__VIEWSTATEGENERATOR'),
      '__VIEWSTATEENCRYPTED': '',
      'txtUsername': username,
      'txtPassword': password,
      'btnLogin': 'ورود سمت سرور ',
    });
    print('POST B isLoginPage=${respB.contains('txtUsernamePlain')}');
    print('  error label: ${_label(respB, 'lblLoginError')}');

    // --- Variant C: the wrong password, to see the error text for bad creds ---
    print('');
    print('=== VARIANT C: deliberately wrong password (control) ===');
    final cookiesC = <String, String>{};
    final pageC = await _get(client, _base, cookiesC);
    final capC = await _getBytes(client, '${_base}UserControls/Captcha.ashx', cookiesC);
    final solC = CaptchaSolver().solve(capC);
    final respC = await _post(client, _base, cookiesC, {
      '__VIEWSTATE': _input(pageC, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': _input(pageC, '__VIEWSTATEGENERATOR'),
      '__VIEWSTATEENCRYPTED': '',
      'txtUsername': username,
      'txtPassword': 'definitely-wrong-password',
      'txtCaptcha': solC.text!,
      'btnLogin': 'ورود سمت سرور ',
    });
    print('POST C isLoginPage=${respC.contains('txtUsernamePlain')}');
    print('  error label: ${_label(respC, 'lblLoginError')}');
  } finally {
    client.close(force: true);
  }
}

String _input(String html, String id) {
  final m = RegExp('id="' + RegExp.escape(id) + r'"[^>]*value="([^"]*)"')
      .firstMatch(html);
  return m?.group(1) ?? '';
}

String? _label(String html, String id) {
  final m = RegExp('<label[^>]*id="' + RegExp.escape(id) + r'"[^>]*>(.*?)</label>',
      dotAll: true)
      .firstMatch(html);
  final t = m?.group(1)?.replaceAll(RegExp(r'\s+'), ' ').trim();
  return (t == null || t.isEmpty) ? null : t;
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
