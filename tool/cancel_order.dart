/// A live reproduction of the app's **full** flow, in the app's order, ending
/// in the cancel that failed on the device.
///
/// The device's cancel reported success while the portal kept the meal and
/// the ledger recorded nothing. The adapter's cancel, run on its own, works
/// (proved by `cancel_repro.dart`). So the difference is the calls that
/// surround it.
///
/// The app's order on a refresh is:
///   1. the table read   — `fetchBookableMenus`  (navigates to next week)
///   2. the sync         — `fetchBalance`, `fetchReservations`, transactions
///   3. the cancel       — `client.cancel`
///
/// This runs exactly that, through the app's own client, and reports the
/// outcome and the portal's state at each step.
///
/// Usage: `dart run tool/cancel_order.dart <studentId> <password>`
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

final _target = DateTime.utc(2026, 10, 25);
const _targetSlot = MealSlot.breakfast;

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run tool/cancel_order.dart <studentId> <password>');
    return;
  }
  final user = args[0];
  final pass = args[1];

  final clock = SyncedServerClock();
  final transport = PortalTransport(baseUri: Uri.parse(_base), clock: clock);
  final client = CullinanPortalClient(transport: transport);

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
    final session = Session(
      account: user,
      cookies: transport.jars.jarFor(user).cookies,
      establishedAt: DateTime.now().toUtc(),
    );
    print('login OK\n');

    // ---- 1. the table read ------------------------------------------------
    print('=== 1. fetchBookableMenus (the table read)');
    final menus = await client.fetchBookableMenus(session);
    print('  menus: ${menus.menus.length}  dates: ${menus.dates.length}');

    // ---- 2. the sync ------------------------------------------------------
    print('\n=== 2. the sync');
    final balance = await client.fetchBalance(session);
    print('  credit: ${balance.amountRial}');
    final reservations = await client.fetchReservations(session);
    print('  reservations: ${reservations.length}');
    print('  target present: '
        '${reservations.any((r) => _isTarget(r.date) && r.slot == _targetSlot)}');
    final transactions = await client.fetchTransactions(session);
    print('  transactions: ${transactions.length}');

    // ---- 3. the cancel ----------------------------------------------------
    print('\n=== 3. the cancel');
    final outcome =
        await client.cancel(session, MealRef(date: _target, slot: MealSlot.breakfast));
    print('  outcome: $outcome');
    print('  is CancelSucceeded: ${outcome is CancelSucceeded}');

    // ---- 4. what the portal holds ----------------------------------------
    final after = await client.fetchReservations(session);
    final balanceAfter = await client.fetchBalance(session);
    final ledger = await client.fetchTransactions(session);
    print('\n=== 4. the portal\'s state');
    print('  reservations now: ${after.length}');
    print('  target still held: '
        '${after.any((r) => _isTarget(r.date) && r.slot == _targetSlot)}');
    print('  credit now: ${balanceAfter.amountRial}');
    print('  transactions now: ${ledger.length}');

    // ---- 5. restore -------------------------------------------------------
    if (outcome is CancelSucceeded &&
        !after.any((r) => _isTarget(r.date) && r.slot == _targetSlot)) {
      print('\n=== 5. restoring the meal');
      final target = reservations.firstWhere((r) => _isTarget(r.date));
      final offering = MealOffering(
        date: target.date,
        slot: target.slot,
        hall: target.hall,
        option: target.option,
        reservable: true,
      );
      try {
        await client.reserve(session, offering);
        print('  re-booked: ${_d(target.date)} ${target.slot.name}');
      } catch (e) {
        print('  !! re-book threw: $e');
      }
      final balance2 = await client.fetchBalance(session);
      print('  credit now: ${balance2.amountRial}');
    }
  } catch (e, st) {
    print('EXCEPTION: $e');
    print(st.toString().split('\n').take(8).join('\n'));
  } finally {
    transport.close();
  }
}

bool _isTarget(DateTime d) =>
    d.year == _target.year && d.month == _target.month && d.day == _target.day;

String _d(DateTime date) => date.toIso8601String().substring(0, 10);

String _input(String html, String id) {
  final m = RegExp('id="' + RegExp.escape(id) + r'"[^>]*value="([^"]*)"')
      .firstMatch(html);
  return m?.group(1) ?? '';
}
