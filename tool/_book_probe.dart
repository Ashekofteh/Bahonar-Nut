/// READ-ONLY: the portal's own bookable days, and the account's reservations.
library;

// ignore_for_file: avoid_print

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/adapter/cullinan_client.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:bahonar_nut/transport/http_transport.dart';

const _base = 'https://nut.uk.ac.ir/';

Future<void> main(List<String> args) async {
  final clock = SyncedServerClock();
  final transport = PortalTransport(baseUri: Uri.parse(_base), clock: clock);
  final client = CullinanPortalClient(transport: transport);
  final challenge = await client.beginLogin(args[0]);
  if (challenge == null) { print('no challenge'); return; }
  final sol = CaptchaSolver().solve(challenge.imageBytes);
  if (sol.text == null) { print('solver declined'); return; }
  final session = await client.completeLogin(
      username: args[0], password: args[1],
      challenge: LoginChallengeResponse(sol.text!));
  if (session == null) { print('login failed'); return; }
  print('LOGIN OK portal now: ${clock.portalNow}');

  final bookable = await client.fetchBookableMenus(session, days: 7);
  print('--- bookable days: ${bookable.dates.length} ---');
  for (final d in bookable.dates) {
    final slots = bookable.menus.where((m) => m.date == d).map((m) => m.slot.name).join(",");
    print('  $d  menus=$slots');
  }
  for (final m in bookable.menus) {
    print('  menu ${m.date} ${m.slot.name} reservable=${m.reservable} '
        'dishes=${m.dishes.map((d) => "${d.id}:${d.name}[${d.priceRial}]").join(" | ")}');
  }

  final res = await client.fetchReservations(session);
  print('--- reservations: ${res.length} ---');
  for (final r in res) {
    print('  ${r.date} ${r.slot.name} ${r.state.name} ${r.option.name}');
  }
}
