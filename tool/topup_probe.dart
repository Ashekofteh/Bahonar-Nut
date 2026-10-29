/// Read-only probe of the ePay top-up page.
///
/// It logs in, reads the ePay page, and reports the banks, the amount bounds
/// and the defaults. It does **not** submit a payment: a payment request
/// mints a gateway token, and that is left to the app's own write path.
///
/// Usage: `dart run tool/topup_probe.dart <studentId> <password>`
library;

// One-shot live action tool: stdout printing is the entire point.
// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/transport/http_transport.dart';

const _base = 'https://nut.uk.ac.ir/';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run tool/topup_probe.dart <studentId> <password>');
    return;
  }
  final user = args[0];
  final pass = args[1];

  final transport = PortalTransport(baseUri: Uri.parse(_base));
  try {
    final page = await transport.get(user, '/');
    final captcha = await transport.getBytes(user, '/UserControls/Captcha.ashx');
    final solution = CaptchaSolver().solve(captcha);
    print('captcha: ${solution.text}');
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
    print('epay status=${epay.statusCode} len=${epay.body.length}');
    print('epay  lblCredit        : ${_label(epay.body, 'lblCredit') ?? "-"}');
    print('epay  lblCafeteriaCredit: ${_label(epay.body, 'lblCafeteriaCredit') ?? "-"}');

    final res = await transport.get(user, '/Reservation/Reservation.aspx');
    print('res   lblCredit        : ${_label(res.body, 'lblCredit') ?? "-"}');
    print('res   lblCafeteriaCredit: ${_label(res.body, 'lblCafeteriaCredit') ?? "-"}');
    for (final m in RegExp(r'اعتبار[^<]{0,40}').allMatches(_text(res.body))) {
      print('  res text: ${m.group(0)}');
    }
    for (final m in RegExp(r'اعتبار[^<]{0,40}').allMatches(_text(epay.body))) {
      print('  epay text: ${m.group(0)}');
    }
    print('amount field value: ${_input(epay.body, 'cphMain_txtPaymentAmount')}');

    for (final m in RegExp(r'<input[^>]*type="image"[^>]*id="cphMain_dataLstBank'
            r'_imgBankLogo_(\d+)"[^>]*src="([^"]*)"')
        .allMatches(epay.body)) {
      final idx = m.group(1)!;
      final logo = m.group(2)!;
      final title = _label(epay.body, 'cphMain_dataLstBank_lblBankTitle_$idx');
      print('bank $idx: logo=$logo title=${title ?? "-"}');
    }

    // The amount bounds, if the page states them anywhere.
    final hints = RegExp(r'(حداقل|حداکثر|حداقل مبلغ|کمترین|بیشترین)[^<]{0,80}')
        .allMatches(_text(epay.body));
    for (final h in hints) {
      print('hint: ${h.group(0)}');
    }
  } catch (e) {
    print('EXCEPTION: $e');
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
