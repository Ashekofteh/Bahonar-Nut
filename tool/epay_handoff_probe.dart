/// The ePay handoff: what does the portal redirect to when the student
/// confirms the payment?
///
/// The redirect is **not** followed — the gateway is a bank site that needs a
/// browser, and the point here is only to learn the URL and the shape of the
/// query the portal builds.
///
/// Usage: `dart run tool/epay_handoff_probe.dart <studentId> <password>`
library;

// One-shot live action tool: stdout printing is the entire point.
// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings

import 'dart:convert';
import 'dart:io';

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/transport/http_transport.dart';

const _base = 'https://nut.uk.ac.ir/';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run tool/epay_handoff_probe.dart <studentId> <password>');
    return;
  }
  final user = args[0];
  final pass = args[1];

  final transport = PortalTransport(baseUri: Uri.parse(_base));
  try {
    final page = await transport.get(user, '/');
    final captcha = await transport.getBytes(user, '/UserControls/Captcha.ashx');
    final solution = CaptchaSolver().solve(captcha);
    final login = await transport.post(user, '/', body: {
      '__VIEWSTATE': _input(page.body, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': _input(page.body, '__VIEWSTATEGENERATOR'),
      '__VIEWSTATEENCRYPTED': '',
      'txtUsername': user,
      'txtPassword': pass,
      'txtCaptcha': solution.text!,
      'btnLogin': 'ورود سمت سرور ',
    });
    if (login.body.contains('txtUsernamePlain')) {
      print('!! LOGIN FAILED');
      return;
    }
    print('login OK');

    final epay = await transport.get(user, '/ePay/ePay_Payment.aspx');

    // Step 2: amount and bank.
    final amountBody = <String, String>{
      '__VIEWSTATE': _input(epay.body, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': _input(epay.body, '__VIEWSTATEGENERATOR'),
      '__VIEWSTATEENCRYPTED': _input(epay.body, '__VIEWSTATEENCRYPTED'),
      '__EVENTTARGET': '',
      '__EVENTARGUMENT': '',
      'ctl00\$cphMain\$txtPaymentAmount': '1000000',
      'ctl00\$cphMain\$dataLstBank\$ctl00\$imgBankLogo.x': '10',
      'ctl00\$cphMain\$dataLstBank\$ctl00\$imgBankLogo.y': '10',
    };
    final confirm = await transport.post(user, '/ePay/ePay_Payment.aspx',
        body: amountBody);
    print('confirm: status=${confirm.statusCode} len=${confirm.body.length}');

    // Step 3: confirm the payment — but do not follow the redirect.
    final payBody = <String, String>{
      '__VIEWSTATE': _input(confirm.body, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': _input(confirm.body, '__VIEWSTATEGENERATOR'),
      '__VIEWSTATEENCRYPTED': _input(confirm.body, '__VIEWSTATEENCRYPTED'),
      '__EVENTTARGET': '',
      '__EVENTARGUMENT': '',
      'ctl00\$cphMain\$btnPay': 'پرداخت',
    };

    final raw = HttpClient();
    final cookies = transport.jars.jarFor(user).cookies;
    final req = await raw.postUrl(Uri.parse('${_base}ePay/ePay_Payment.aspx'));
    req.followRedirects = false;
    req.headers.set(HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36');
    req.headers.set(HttpHeaders.refererHeader, '${_base}ePay/ePay_Payment.aspx');
    req.headers.set(HttpHeaders.cookieHeader,
        cookies.entries.map((e) => '${e.key}=${e.value}').join('; '));
    req.headers.contentType =
        ContentType('application', 'x-www-form-urlencoded');
    req.write(payBody.entries
        .map((e) =>
            '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&'));
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();

    print('pay: status=${resp.statusCode} len=${body.length}');
    final location = resp.headers.value(HttpHeaders.locationHeader);
    print('LOCATION: $location');
    if (location != null) {
      final uri = Uri.tryParse(location);
      if (uri != null) {
        print('  host: ${uri.host}  path: ${uri.path}');
        print('  query keys: ${uri.queryParameters.keys.toList()}');
        for (final entry in uri.queryParameters.entries) {
          final v = entry.value;
          print('    ${entry.key} = ${v.length > 80 ? '${v.substring(0, 80)}...' : v}');
        }
      }
    }
    // The body may carry the handoff instead of a redirect.
    for (final m in RegExp(r'postTo\w+\s*\([^;]{0,300}\);').allMatches(body)) {
      print('  CALL: ' + (m.group(0) ?? '').replaceAll(RegExp(r'\s+'), ' '));
    }
    for (final m in RegExp(r'<form[^>]*action="([^"]*)"', dotAll: true)
        .allMatches(body)) {
      print('  form action: ${m.group(1)}');
    }
    for (final m in RegExp(r'<input[^>]*name="([^"]*)"[^>]*value="([^"]*)"')
        .allMatches(body)) {
      final n = m.group(1)!;
      if (n.startsWith('__')) continue;
      print('  hidden: $n = ${m.group(2)}');
    }
    raw.close(force: true);
  } catch (e, st) {
    print('EXCEPTION: $e');
    print(st.toString().split('\n').take(6).join('\n'));
  } finally {
    transport.close();
  }
}

String _input(String html, String id) {
  final m = RegExp('id="' + RegExp.escape(id) + r'"[^>]*value="([^"]*)"')
      .firstMatch(html);
  return m?.group(1) ?? '';
}
