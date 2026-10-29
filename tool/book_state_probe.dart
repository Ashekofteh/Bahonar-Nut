/// READ-ONLY: the whole book's menu, the account's credit and its holdings.
///
/// Why: the F85 device test needs a hunt whose pre-flight can actually pass,
/// and the pre-flight refuses on three counts — no session, no dish chosen, and
/// "the account already holds this meal". So the test needs to know, for a
/// given date and slot, the live price of every dish and whether the account
/// already holds that slot. This prints both.
///
/// Usage: `dart run tool/book_state_probe.dart <studentId> <password>`
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
    if (challenge == null) {
      print('no challenge issued');
      return;
    }
    final solution = CaptchaSolver().solve(challenge.imageBytes);
    if (solution.text == null) {
      print('solver declined');
      return;
    }
    final session = await client.completeLogin(
      username: user,
      password: pass,
      challenge: LoginChallengeResponse(solution.text!),
    );
    print('LOGIN OK');

    final balance = await client.fetchBalance(session);
    print('credit: ${balance.amountRial} Rial');
    print('portal now: ${clock.portalNow}  today: ${clock.portalTodayUtc}');
    print('');

    final menus = await client.fetchBookableMenus(session, days: 7);
    print('--- bookable menus ---');
    for (final menu in menus.menus) {
      print('${_iso(menu.date)}  ${menu.slot.name}  '
          'reservable=${menu.reservable}');
      for (final hall in menu.halls) {
        print('    hall id=${hall.id}  ${hall.name}');
      }
      for (final dish in menu.dishes) {
        print('    dish id=${dish.id}  ${dish.name}  [${dish.priceRial}]');
      }
    }

    print('');
    final reservations = await client.fetchReservations(session);
    print('--- holdings (${reservations.length}) ---');
    for (final r in reservations) {
      print('${_iso(r.date)}  ${r.slot.name}  ${r.state.name}  '
          '${r.option.name}  hall=${r.hall.name}');
    }
  } catch (e, stack) {
    print('FAILED: $e');
    print(stack.toString().split('\n').take(6).join('\n'));
  }
}

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';
