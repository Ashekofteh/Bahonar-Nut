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
  await t.post(user, '/', body: {
    '__VIEWSTATE': _input(page.body, '__VIEWSTATE'),
    '__VIEWSTATEGENERATOR': _input(page.body, '__VIEWSTATEGENERATOR'),
    '__VIEWSTATEENCRYPTED': '', 'txtUsername': user, 'txtPassword': pass,
    'txtCaptcha': sol.text!, 'btnLogin': 'ورود سمت سرور ',
  });
  final r = await t.get(user, '/MyCullinan/MyePayList.aspx');
  File('recon/eplist.html').writeAsStringSync(r.body);
  print('len=${r.body.length}');
  t.close();
}
String _input(String h, String id) => RegExp('id="' + RegExp.escape(id) + r'"[^>]*value="([^"]*)"').firstMatch(h)?.group(1) ?? '';
