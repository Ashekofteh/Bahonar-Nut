library;
import 'dart:convert';
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
  await t.post(user, '/', body: {
    '__VIEWSTATE': _input(page.body, '__VIEWSTATE'),
    '__VIEWSTATEGENERATOR': _input(page.body, '__VIEWSTATEGENERATOR'),
    '__VIEWSTATEENCRYPTED': '', 'txtUsername': user, 'txtPassword': pass,
    'txtCaptcha': sol.text!, 'btnLogin': 'ورود سمت سرور ',
  });
  final epay = await t.get(user, '/ePay/ePay_Payment.aspx');
  for (final bank in ['ctl00', 'ctl01']) {
    final amountBody = <String,String>{
      '__VIEWSTATE': _input(epay.body, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': _input(epay.body, '__VIEWSTATEGENERATOR'),
      '__VIEWSTATEENCRYPTED': _input(epay.body, '__VIEWSTATEENCRYPTED'),
      '__EVENTTARGET': '', '__EVENTARGUMENT': '',
      'ctl00\$cphMain\$txtPaymentAmount': '120000',
      'ctl00\$cphMain\$dataLstBank\$$bank\$imgBankLogo.x': '10',
      'ctl00\$cphMain\$dataLstBank\$$bank\$imgBankLogo.y': '10',
    };
    final confirm = await t.post(user, '/ePay/ePay_Payment.aspx', body: amountBody);
    // The confirm page's bank cell, so the app can label the bank.
    final bankCell = RegExp(r'بانک</label>(.{0,900})', dotAll: true).firstMatch(confirm.body)?.group(1);
    final payBody = <String,String>{
      '__VIEWSTATE': _input(confirm.body, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': _input(confirm.body, '__VIEWSTATEGENERATOR'),
      '__VIEWSTATEENCRYPTED': _input(confirm.body, '__VIEWSTATEENCRYPTED'),
      '__EVENTTARGET': '', '__EVENTARGUMENT': '',
      'ctl00\$cphMain\$btnPay': 'پرداخت',
    };
    final raw = HttpClient();
    final cookies = t.jars.jarFor(user).cookies;
    final req = await raw.postUrl(Uri.parse('${_base}ePay/ePay_Payment.aspx'));
    req.followRedirects = false;
    req.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36');
    req.headers.set(HttpHeaders.cookieHeader, cookies.entries.map((e) => '${e.key}=${e.value}').join('; '));
    req.headers.contentType = ContentType('application', 'x-www-form-urlencoded');
    req.write(payBody.entries.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&'));
    final resp = await req.close();
    final loc = resp.headers.value(HttpHeaders.locationHeader);
    final respBody = await resp.transform(utf8.decoder).join();
    print('bank=$bank -> ${loc ?? "(no redirect)"}');
    if (loc == null) {
      File('recon/bank_${bank}_pay.html').writeAsStringSync(respBody);
    }
    raw.close(force: true);
  }
  t.close();
}
String _input(String h, String id) => RegExp('id="' + RegExp.escape(id) + r'"[^>]*value="([^"]*)"').firstMatch(h)?.group(1) ?? '';
