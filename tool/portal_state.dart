/// READ-ONLY: the account's current portal state.
///
/// Books and cancels nothing. Reports the held meals, the credit and the
/// last ledger rows, so a change made by the app can be checked against the
/// portal.
///
/// Usage: `dart run tool/portal_state.dart <studentId> <password>`
library;

// One-shot live probe tool: stdout printing is the entire point.
// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/adapter/cullinan_client.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:bahonar_nut/transport/http_transport.dart';

const _base = 'https://nut.uk.ac.ir/';

Future<void> main(List<String> args) async {
  final user = args[0];
  final pass = args[1];

  final clock = SyncedServerClock();
  final transport = PortalTransport(baseUri: Uri.parse(_base), clock: clock);
  final client = CullinanPortalClient(transport: transport);

  try {
    final challenge = await client.beginLogin(user);
    if (challenge != null) {
      final answer = CaptchaSolver().solve(
        await transport.getBytes(user, '/UserControls/Captcha.ashx'),
      );
      await client.completeLogin(
        username: user,
        password: pass,
        challenge: LoginChallengeResponse(answer.text!),
      );
    }
    final session = Session(
      account: user,
      cookies: transport.jars.jarFor(user).cookies,
      establishedAt: DateTime.now().toUtc(),
    );

    final reservations = await client.fetchReservations(session);
    print('reservations: ${reservations.length}');
    for (final r in reservations) {
      print('  ${_d(r.date)} ${r.slot.name} ${r.option.name}');
    }

    final balance = await client.fetchBalance(session);
    print('credit: ${balance.amountRial}');

    final ledger = await client.fetchTransactions(session);
    print('transactions: ${ledger.length}');
    for (final t in ledger.take(8)) {
      print('  $t');
    }
  } catch (e, st) {
    print('EXCEPTION: $e');
    print(st.toString().split('\n').take(8).join('\n'));
  } finally {
    transport.close();
  }
}

String _d(DateTime date) => date.toIso8601String().substring(0, 10);
