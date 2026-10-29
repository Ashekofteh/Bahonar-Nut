/// READ-ONLY: the official menu for a date, so the hunt's dish list can be
/// chosen from what the portal actually offers.
library;

// ignore_for_file: avoid_print

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/adapter/cullinan_client.dart';
import 'package:bahonar_nut/core/models.dart';
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

  for (final iso in args.sublist(2)) {
    final date = DateTime.parse(iso).toUtc();
    try {
      final menus = await client.fetchMenu(session, date);
      print('--- menu for $iso ---');
      for (final m in menus) {
        print('  ${m.slot.name} reservable=${m.reservable}');
        for (final h in m.halls) {
          print('     hall ${h.id} ${h.name}');
        }
        for (final d in m.dishes) {
          print('     dish ${d.id} ${d.name} [${d.priceRial}]');
        }
      }
    } catch (e) {
      print('--- $iso FAILED: $e');
    }
  }
}
