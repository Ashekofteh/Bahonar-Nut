/// A live top-up probe: mints a real gateway token against the portal.
///
/// It stops **before** the payment — the card is the student's, and the
/// gateway is a page the student completes in the app's WebView. What it
/// proves is the half the app owns:
///
///   1. the top-up page is read (balance, banks);
///   2. the amount is accepted by the portal;
///   3. the confirmation page comes back;
///   4. the `btnPay` post answers with a redirect to the real gateway,
///      carrying a token;
///   5. the gateway URL is actually reachable and serves the bank's page.
///
/// Usage: `dart run tool/top_up_live.dart <studentId> <password> [amountRial]`
library;

// One-shot live action tool: stdout printing is the entire point.
// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings

import 'dart:convert';
import 'dart:io';

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/adapter/cullinan_client.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:bahonar_nut/transport/http_transport.dart';

const _base = 'https://nut.uk.ac.ir/';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run tool/top_up_live.dart <studentId> <password> '
        '[amountRial]');
    return;
  }
  final user = args[0];
  final pass = args[1];
  final amount = args.length > 2 ? int.parse(args[2]) : 150000;

  final clock = SyncedServerClock();
  final transport = PortalTransport(baseUri: Uri.parse(_base), clock: clock);
  final client = CullinanPortalClient(transport: transport);

  try {
    // ------------------------------------------------------------- LOGIN
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
    print('login OK; clock synced = ${clock.isSynced}');

    final session = Session(
      account: user,
      cookies: transport.jars.jarFor(user).cookies,
      establishedAt: DateTime.now().toUtc(),
    );

    // ------------------------------------------------------- THE PAGE
    final topUpPage = await client.fetchTopUpPage(session);
    print('balance: ${topUpPage.balanceRial} Rial');
    print('banks: ${topUpPage.banks.length}');
    for (final bank in topUpPage.banks) {
      print('  - ${bank.name}  id=${bank.id}  logo=${bank.logoPath}');
    }

    if (topUpPage.banks.isEmpty) {
      print('!! no banks');
      return;
    }

    // ------------------------------------------------------ THE TOKEN
    // The first bank is the one the portal's own confirmation page proves
    // works; the second errors when it is used (F57).
    final bank = topUpPage.banks.first;

    print('\nstarting a top-up of $amount Rial via ${bank.name}...');
    final Uri gateway;
    try {
      gateway = await client.beginTopUp(session, amount, bank);
    } catch (e) {
      print('!! beginTopUp failed: $e');
      return;
    }

    print('gateway: $gateway');
    print('  host: ${gateway.host}');
    print('  token: ${gateway.queryParameters['token']}');

    // ------------------------------------------------- IS IT REACHABLE
    // The gateway is NOT reachable from the app's transport (F55) — it needs
    // a browser. So it is fetched with a plain client here, purely to
    // prove the URL the app hands the WebView is a real one.
    print('\nchecking the gateway...');
    final probe = await _fetchGateway(gateway);
    if (probe == null) {
      print('!! the gateway did not answer');
      return;
    }
    print('  status: ${probe.status}');
    print('  bytes: ${probe.length}');
    print('  title: ${probe.title}');
    print('  looks like a payment page: ${probe.looksLikePayment}');

    // ------------------------------------------------------ THE LIST
    final payments = await client.fetchTopUpPayments(session);
    print('\npayment list: ${payments.length} rows');
    for (final payment in payments.take(3)) {
      print('  - ${payment.amountRial} ${payment.status.name} '
          '${payment.message ?? ""}');
    }

    print('\n=== SUMMARY ===');
    print('token minted: yes');
    print('gateway reachable: ${probe.status == 200}');
  } catch (e, st) {
    print('EXCEPTION: $e');
    print(st.toString().split('\n').take(6).join('\n'));
  } finally {
    transport.close();
  }
}

class _GatewayPage {
  _GatewayPage(this.status, this.length, this.title, this.looksLikePayment);

  final int status;
  final int length;
  final String title;
  final bool looksLikePayment;
}

/// Fetches the gateway page with a client that is NOT the app's transport.
///
/// The app cannot do this — that is the whole reason the WebView exists
/// (F55) — so it is done here with a throwaway client, to prove the URL is
/// real before the student is sent to it.
Future<_GatewayPage?> _fetchGateway(Uri gateway) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final request = await client.getUrl(gateway);
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/113.0.0.0',
    );
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();

    final titleMatch =
        RegExp(r'<title>(.*?)</title>', dotAll: true).firstMatch(body);
    final title = titleMatch?.group(1)?.trim() ?? '';

    return _GatewayPage(
      response.statusCode,
      body.length,
      title,
      body.contains('شماره کارت') ||
          body.contains('مبلغ') ||
          body.contains('پرداخت'),
    );
  } catch (e) {
    print('  gateway fetch failed: $e');
    return null;
  } finally {
    client.close(force: true);
  }
}

String _input(String html, String id) {
  final m = RegExp('id="' + RegExp.escape(id) + r'"[^>]*value="([^"]*)"')
      .firstMatch(html);
  return m?.group(1) ?? '';
}
