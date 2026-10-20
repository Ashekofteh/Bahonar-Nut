/// Diagnostic CLI tool: stdout printing is the entire point.
// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings
///
/// Usage: `dart run tool/transport_debug.dart <studentId> <password>`
///
/// The credentials are taken from argv and never written to disk or logged.
library;

import 'dart:io';

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/transport/http_transport.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln(
        'usage: dart run tool/transport_debug.dart <studentId> <password>');
    exitCode = 2;
    return;
  }
  final t = PortalTransport(baseUri: Uri.parse('https://nut.uk.ac.ir/'));
  final user = args[0];
  final pass = args[1];
  try {
    final page = await t.get(user, '/');
    final vs = _input(page.body, '__VIEWSTATE');
    final vsg = _input(page.body, '__VIEWSTATEGENERATOR');
    print('page len=${page.body.length} vs=${vs.length} vsg=$vsg');

    final cap = await t.getBytes(user, '/UserControls/Captcha.ashx');
    print('captcha ${cap.length} bytes, '
        'cookies=${t.jars.jarFor(user).cookies.keys.toList()}');

    final sol = CaptchaSolver().solve(cap);
    print('solved: ${sol.text}');

    final resp = await t.post(user, '/', body: {
      '__VIEWSTATE': vs,
      '__VIEWSTATEGENERATOR': vsg,
      '__VIEWSTATEENCRYPTED': '',
      'txtUsername': user,
      'txtPassword': pass,
      'txtCaptcha': sol.text!,
      'btnLogin': 'ورود سمت سرور ',
    });
    print('POST status=${resp.statusCode}');
    print('isLoginPage=${resp.body.contains('txtUsernamePlain')}');
    print('error: ${_label(resp.body, 'lblLoginError')}');
    print('location: ${resp.headers['location']}');
    print('cookies now: ${t.jars.jarFor(user).cookies.keys.toList()}');
  } catch (e, st) {
    print('FAILED: $e');
    print(st.toString().split('\n').take(5).join('\n'));
  } finally {
    t.close();
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
  final x = m?.group(1)?.replaceAll(RegExp(r'\s+'), ' ').trim();
  return (x == null || x.isEmpty) ? null : x;
}
