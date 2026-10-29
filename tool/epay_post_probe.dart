/// Probe of the ePay POST: what does the portal answer when an amount and a
/// bank are submitted?
///
/// The bank itself is NOT driven from here — the gateway needs a card, which
/// is the user's to enter. This probe stops at the handoff and reports it, so
/// the app's own flow can be built against the real shape rather than a guess.
///
/// Usage: `dart run tool/epay_post_probe.dart <studentId> <password> [amount]`
library;

// One-shot live action tool: stdout printing is the entire point.
// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings

import 'dart:io';

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/transport/http_transport.dart';

const _base = 'https://nut.uk.ac.ir/';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run tool/epay_post_probe.dart <studentId> <password> '
        '[amountRial]');
    return;
  }
  final user = args[0];
  final pass = args[1];
  final amount = args.length > 2 ? args[2] : '1000000';

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
    print('epay GET: status=${epay.statusCode} len=${epay.body.length}');

    // The form's own state, plus the amount and the chosen bank.
    final body = <String, String>{
      '__VIEWSTATE': _input(epay.body, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': _input(epay.body, '__VIEWSTATEGENERATOR'),
      '__VIEWSTATEENCRYPTED': _input(epay.body, '__VIEWSTATEENCRYPTED'),
      '__EVENTTARGET': '',
      '__EVENTARGUMENT': '',
      'ctl00\$cphMain\$txtPaymentAmount': amount,
      // The bank logo IS the submit button: an image input posts its own
      // name plus the click coordinates.
      'ctl00\$cphMain\$dataLstBank\$ctl00\$imgBankLogo.x': '10',
      'ctl00\$cphMain\$dataLstBank\$ctl00\$imgBankLogo.y': '10',
    };

    final post = await transport.post(user, '/ePay/ePay_Payment.aspx', body: body);
    File('recon/epay_post_response.html').writeAsStringSync(post.body);
    File('recon/epay_post_body.txt')
        .writeAsStringSync(body.entries.map((e) => '${e.key}=${e.value}').join('\n'));
    print('epay POST: status=${post.statusCode} len=${post.body.length}');
    File('recon/epay_amount_resp.html').writeAsStringSync(post.body);
    final amtText = _text(post.body);
    for (final m in RegExp(r'(حداقل|حداکثر|مبلغ|اعتبار|معتبر|درست نیست|خطا)[^<]{0,80}').allMatches(amtText)) {
      print('  amt: ${m.group(0)}');
    }

    // Step 3: the confirmation page's Pay button mints the gateway token.
    final confirmBody = <String, String>{
      '__VIEWSTATE': _input(post.body, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': _input(post.body, '__VIEWSTATEGENERATOR'),
      '__VIEWSTATEENCRYPTED': _input(post.body, '__VIEWSTATEENCRYPTED'),
      '__EVENTTARGET': '',
      '__EVENTARGUMENT': '',
      'ctl00\$cphMain\$btnPay': 'پرداخت',
    };
    final pay = await transport.post(user, '/ePay/ePay_Payment.aspx',
        body: confirmBody);
    File('recon/epay_pay_response.html').writeAsStringSync(pay.body);
    print('epay PAY: status=${pay.statusCode} len=${pay.body.length}');
    print('  location: ${pay.headers['location']}');
    for (final m in RegExp(r'postTo\w+\s*\([^;]{0,300}\);').allMatches(pay.body)) {
      print('  CALL: ' + (m.group(0) ?? '').replaceAll(RegExp(r'\s+'), ' '));
    }
    for (final m in RegExp(r'<form[^>]*action="([^"]*)"', dotAll: true)
        .allMatches(pay.body)) {
      print('  form action: ${m.group(1)}');
    }
    for (final m in RegExp(r'<input[^>]*name="([^"]*)"[^>]*value="([^"]*)"')
        .allMatches(pay.body)) {
      if (m.group(1)!.startsWith('__')) continue;
      print('  hidden: ${m.group(1)} = ${m.group(2)}');
    }
    final payText = _text(pay.body);
    for (final m in RegExp(r'(مبلغ|اعتبار|درگاه|شماره)[^<]{0,50}').allMatches(payText)) {
      print('  text: ${m.group(0)}');
    }
    return;
    print('  location: ${post.headers['location']}');

    // The handoff the portal scripts.
    for (final m in RegExp(r'function\s+(postTo\w+)\s*\(([^)]*)\)')
        .allMatches(post.body)) {
      print('  handoff fn: ${m.group(1)}(${m.group(2)})');
    }
    for (final m in RegExp(r'(postTo\w+)\s*\(([^;]{0,200})\);')
        .allMatches(post.body)) {
      print('  call: ${m.group(0)!.replaceAll('\n', ' ').trim()}');
    }
    for (final m in RegExp(r'<form[^>]*action="([^"]*)"', dotAll: true)
        .allMatches(post.body)) {
      print('  form action: ${m.group(1)}');
    }
    for (final m in RegExp(r'name="([^"]*)"\s+value="([^"]*)"')
        .allMatches(post.body)) {
      if (m.group(1) == '__VIEWSTATE') continue;
      print('  hidden: ${m.group(1)} = ${m.group(2)}');
    }

    // Any message the portal says about the amount.
    for (final id in ['cphMain_alertBoxValue', 'cphMain_lblMessage', 'lblMessage']) {
      final t = _label(post.body, id);
      if (t != null) print('  message[$id]: $t');
    }
    final text = _text(post.body);
    for (final m in RegExp(r'(حداقل|حداکثر|مبلغ)[^<]{0,60}').allMatches(text)) {
      print('  text: ${m.group(0)}');
    }
  } catch (e, st) {
    print('EXCEPTION: $e');
    print(st.toString().split('\n').take(6).join('\n'));
  } finally {
    transport.close();
  }
}

String _text(String html) => html
    .replaceAll(RegExp(r'<script.*?</script>', dotAll: true), ' ')
    .replaceAll(RegExp(r'<[^>]*>'), ' ')
    .replaceAll('&nbsp;', ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

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
