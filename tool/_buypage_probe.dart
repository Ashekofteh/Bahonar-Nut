/// READ-ONLY: the buy page's own date filter and the rows it renders.
library;

// ignore_for_file: avoid_print

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/adapter/cullinan_client.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/core/persian.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:bahonar_nut/transport/http_transport.dart';

const _base = 'https://nut.uk.ac.ir/';

String j(DateTime d) {
  final x = toJalali(d);
  return '${x.year}/${x.month.toString().padLeft(2, '0')}/${x.day.toString().padLeft(2, '0')}';
}

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
  print('portal today: ${clock.portalTodayUtc}  jalali ${j(clock.portalTodayUtc)}');

  for (var d = 22; d <= 30; d++) {
    final date = DateTime.utc(2026, 10, d);
    try {
      final page = await client.fetchBasket(session, cursor: j(date));
      print('$date (${j(date)}) -> ${page.listings.length} listing(s)');
      for (final l in page.listings) {
        print('    ${l.slot.name} hall=${l.hall.name} dish=${l.option.name} [${l.priceRial}]');
      }
    } catch (e) {
      print('$date -> ERROR $e');
    }
  }
}
