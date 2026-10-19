/// READ-ONLY: read the account's transaction ledger to see what changed.
///
/// The credit dropped from 1,000,000 to 500,000 and a 1405/07/30 lunch now
/// appears booked and editable. This reads the transactions page to find out
/// what caused it. Books and cancels nothing.
///
/// Usage: `dart run tool/ledger_check.dart <studentId> <password>`
// Read-only diagnostic probe.
// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings

library;

import 'dart:io';

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/transport/http_transport.dart';

const _base = 'https://nut.uk.ac.ir/';

Future<void> main(List<String> args) async {
  final username = args[0];
  final password = args[1];
  final transport = PortalTransport(baseUri: Uri.parse(_base));

  try {
    final page = await transport.get(username, '/');
    final captcha =
        await transport.getBytes(username, '/UserControls/Captcha.ashx');
    final solution = CaptchaSolver().solve(captcha);
    final login = await transport.post(username, '/', body: {
      '__VIEWSTATE': _input(page.body, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': _input(page.body, '__VIEWSTATEGENERATOR'),
      '__VIEWSTATEENCRYPTED': '',
      'txtUsername': username,
      'txtPassword': password,
      'txtCaptcha': solution.text!,
      'btnLogin': 'ورود سمت سرور ',
    });
    if (login.body.contains('txtUsernamePlain')) {
      print('!! LOGIN FAILED');
      return;
    }
    print('credit now: ${_label(login.body, 'lblCredit')}');

    // The transactions page.
    final tx = await transport.get(username, '/MyCullinan/MyTransaction.aspx');
    File('captures/40_transactions.html').writeAsStringSync(tx.body);
    print('transactions page: ${tx.body.length} chars -> captures/40_transactions.html');

    // The main grid, then each detail grid.
    for (final grid in ['grdContent']) {
      _dump(tx.body, grid, 'transactions');
    }
    for (final m in RegExp(r'id="(cphMain_grdContent_grdDetail_\d+)"').allMatches(tx.body)) {
      _dump(tx.body, m.group(1)!, 'detail');
    }
  } catch (e, st) {
    print('EXCEPTION: $e');
    print(st.toString().split('\n').take(6).join('\n'));
  } finally {
    transport.close();
  }
}

void _dump(String html, String gridId, String label) {
  final table = RegExp('<table[^>]*id="[^"]*' + RegExp.escape(gridId) +
          r'"[^>]*>(.*?)</table>',
          dotAll: true)
      .firstMatch(html);
  if (table == null) return;

  final headers = <String>[];
  for (final h in RegExp(r'<th[^>]*>(.*?)</th>', dotAll: true)
      .allMatches(table.group(1)!)) {
    headers.add(_text(h.group(1)!));
  }
  if (headers.isNotEmpty) {
    print('\n  [$label $gridId] headers: $headers');
  }

  for (final m in RegExp(r'<tr[^>]*>(.*?)</tr>', dotAll: true)
      .allMatches(table.group(1)!)) {
    final cells = RegExp(r'<td[^>]*>(.*?)</td>', dotAll: true)
        .allMatches(m.group(1)!)
        .map((c) => _text(c.group(1)!))
        .toList();
    if (cells.isEmpty) continue;
    if (cells.every((c) => c.isEmpty)) continue;
    print('    ${cells.join(' | ')}');
  }
}

String _text(String html) => html
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
