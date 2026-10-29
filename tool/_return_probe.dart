library;
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
  for (final p in [
    '/ePay/ePay_Result.aspx', '/ePay/ePay_PaymentResult.aspx',
    '/ePay/PaymentResult.aspx', '/ePay/ePay_Return.aspx',
    '/ePay/ePay_Verify.aspx', '/MyCullinan/MyePayList.aspx',
    '/ePay/ePay_Invoice.aspx', '/ePay/ePay_Purchase.aspx',
  ]) {
    try {
      final r = await t.get(user, p);
      final loginPage = r.body.contains('txtUsernamePlain');
      print('$p -> ${r.statusCode} len=${r.body.length} loginPage=$loginPage');
    } catch (e) {
      print('$p -> EXCEPTION $e');
    }
  }
  t.close();
}
String _input(String h, String id) => RegExp('id="' + RegExp.escape(id) + r'"[^>]*value="([^"]*)"').firstMatch(h)?.group(1) ?? '';
