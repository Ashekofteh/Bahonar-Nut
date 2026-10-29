library;
import 'dart:io';
import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/transport/http_transport.dart';
const _base = 'https://nut.uk.ac.ir/';
Future<void> main(List<String> args) async {
  final t = PortalTransport(baseUri: Uri.parse(_base));
  final user = args[0], pass = args[1];
  final page = await t.get(user, '/');
  final cap = await t.getBytes(user, '/UserControls/Captcha.ashx');
  final sol = CaptchaSolver().solve(cap);
  final login = await t.post(user, '/', body: {
    '__VIEWSTATE': _input(page.body, '__VIEWSTATE'),
    '__VIEWSTATEGENERATOR': _input(page.body, '__VIEWSTATEGENERATOR'),
    '__VIEWSTATEENCRYPTED': '', 'txtUsername': user, 'txtPassword': pass,
    'txtCaptcha': sol.text!, 'btnLogin': 'ورود سمت سرور ',
  });
  final epay = await t.get(user, '/ePay/ePay_Payment.aspx');
  for (final spec in [
    ['ctl00', '120000'], ['ctl01', '120000'],
    ['ctl00', '50000'], ['ctl00', '6000000'],
  ]) {
    final bank = spec[0], amount = spec[1];
    final body = <String,String>{
      '__VIEWSTATE': _input(epay.body, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': _input(epay.body, '__VIEWSTATEGENERATOR'),
      '__VIEWSTATEENCRYPTED': _input(epay.body, '__VIEWSTATEENCRYPTED'),
      '__EVENTTARGET': '', '__EVENTARGUMENT': '',
      'ctl00\$cphMain\$txtPaymentAmount': amount,
      'ctl00\$cphMain\$dataLstBank\$$bank\$imgBankLogo.x': '10',
      'ctl00\$cphMain\$dataLstBank\$$bank\$imgBankLogo.y': '10',
    };
    final r = await t.post(user, '/ePay/ePay_Payment.aspx', body: body);
    final alert = _label(r.body, 'cphMain_alertBoxValue');
    final hasPay = r.body.contains('cphMain_btnPay');
    File('recon/epay_${bank}_$amount.html').writeAsStringSync(r.body);
    print('bank=$bank amount=$amount -> len=${r.body.length} confirmPage=$hasPay alert="${alert ?? "-"}"');
  }
  t.close();
}
String _input(String h, String id) => RegExp('id="' + RegExp.escape(id) + r'"[^>]*value="([^"]*)"').firstMatch(h)?.group(1) ?? '';
String? _label(String h, String id) {
  final m = RegExp('<label[^>]*id="' + RegExp.escape(id) + r'"[^>]*>(.*?)</label>', dotAll: true).firstMatch(h);
  final t = m?.group(1)?.replaceAll(RegExp(r'\s+'), ' ').trim();
  return (t == null || t.isEmpty) ? null : t;
}
