/// Read-only probe: dump the live FoodBasketBuy.aspx form structure.
///
/// The recon snapshot (2026-10-18) showed that page rendering only the
/// student's own three held meals. Before building the sniping adapter we must
/// know whether the *marketplace* is reachable there, and if so how: which
/// controls select the date, and does a "load"/"reload" button populate
/// other students' listings.
///
/// Purely read-only: GETs and the page's own filter postbacks only.
///
/// Usage: `dart run tool/buy_page_dump.dart <studentId> <password>`
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
    stderr.writeln('usage: dart run tool/buy_page_dump.dart <studentId> <password>');
    exitCode = 2;
    return;
  }

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  final cookies = <String, String>{};

  try {
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
      '__EVENTTARGET': '',
      '__EVENTARGUMENT': '',
      '__VIEWSTATEENCRYPTED': '',
      'txtUsername': args[0],
      'txtPassword': args[1],
      'txtCaptcha': solution.text!,
      'btnLogin': 'ورود سمت سرور ',
    });
    if (login.contains('txtUsernamePlain')) {
      stdout.writeln('LOGIN FAILED');
      return;
    }
    stdout.writeln('logged in');

    final buy = await _get(client, '${_base}FoodBasket/FoodBasketBuy.aspx', cookies);
    File('recon/live_buy_page.html').writeAsStringSync(buy);
    stdout.writeln('saved recon/live_buy_page.html (${buy.length} bytes)');

    stdout.writeln('\n--- ALL NAMED CONTROLS ---');
    for (final m in RegExp(r'<(input|select|button|textarea)[^>]*name="([^"]+)"[^>]*>')
        .allMatches(buy)) {
      final tag = m.group(0)!;
      final kind = m.group(1)!;
      final nm = m.group(2)!;
      final idm = RegExp(r'id="([^"]*)"').firstMatch(tag);
      final val = RegExp(r'value="([^"]*)"').firstMatch(tag);
      final type = RegExp(r'type="([^"]*)"').firstMatch(tag);
      stdout.writeln('  $kind ${type != null ? type.group(1) : ''} '
          'name=$nm id=${idm?.group(1) ?? ''} '
          'value=${val != null ? val.group(1) : ''}');
    }

    stdout.writeln('\n--- TABS / HEADERS ---');
    for (final m in RegExp(r'<th[^>]*>(.*?)</th>', dotAll: true).allMatches(buy)) {
      final t = m.group(1)!.replaceAll(RegExp(r'<[^>]+>'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
      if (t.isNotEmpty) stdout.writeln('  TH: $t');
    }

    stdout.writeln('\n--- VISIBLE BODY TEXT (trimmed) ---');
    final body = RegExp(r'<form.*?</form>', dotAll: true).firstMatch(buy);
    final text = (body?.group(0) ?? buy)
        .replaceAll(RegExp(r'<script.*?</script>', dotAll: true), ' ')
        .replaceAll(RegExp(r'<style.*?</style>', dotAll: true), ' ')
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    stdout.writeln(text);

    stdout.writeln('\n--- ALL TABLE IDS ---');
    for (final m in RegExp(r'<table[^>]*id="([^"]*)"[^>]*>').allMatches(buy)) {
      stdout.writeln('  ${m.group(1)}');
    }
  } finally {
    client.close(force: true);
  }
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
