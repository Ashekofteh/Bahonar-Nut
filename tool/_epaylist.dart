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
  final login = await t.post(user, '/', body: {
    '__VIEWSTATE': _input(page.body, '__VIEWSTATE'),
    '__VIEWSTATEGENERATOR': _input(page.body, '__VIEWSTATEGENERATOR'),
    '__VIEWSTATEENCRYPTED': '', 'txtUsername': user, 'txtPassword': pass,
    'txtCaptcha': sol.text!, 'btnLogin': 'ورود سمت سرور ',
  });
  print('login=${!login.body.contains('txtUsernamePlain')}');
  for (final p in ['/MyCullinan/MyePayList.aspx', '/ePay/ePay_Payment.aspx']) {
    final r = await t.get(user, p);
    print('$p -> ${r.statusCode} len=${r.body.length}');
    if (p.contains('ePayList')) {
      final rows = RegExp(r'<tr[^>]*>(.*?)</tr>', dotAll: true).allMatches(r.body);
      for (final row in rows.take(8)) {
        final cells = RegExp(r'<td[^>]*>(.*?)</td>', dotAll: true)
            .allMatches(row.group(1)!)
            .map((c) => c.group(1)!.replaceAll(RegExp(r'<[^>]*>'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim())
            .toList();
        if (cells.isNotEmpty) print('   ${cells.join(' | ')}');
      }
    }
  }
  t.close();
}
String _input(String h, String id) => RegExp('id="' + RegExp.escape(id) + r'"[^>]*value="([^"]*)"').firstMatch(h)?.group(1) ?? '';
