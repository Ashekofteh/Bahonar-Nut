/// READ-ONLY: what the market (the buy page) carries, and the account's credit.
///
/// Why: the F85 device test needs a hunt that can actually reach the hunting
/// stage. The pre-flight demands enough credit for the priority list, so the
/// credit and the market's current listings decide whether the test can run as
/// a real hunt or only as a refusal.
///
/// Usage: `dart run tool/market_state_probe.dart <studentId> <password> [date]
library;

// One-shot live probe tool: stdout printing is the entire point.
// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/adapter/cullinan_client.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/persian.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:bahonar_nut/transport/http_transport.dart';

const _base = 'https://nut.uk.ac.ir/';

Future<void> main(List<String> args) async {
  final user = args[0];
  final pass = args[1];
  final target = args.length > 2 ? DateTime.parse(args[2]) : null;

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
    print('portal now: ${clock.portalNow}');

    for (final date in <DateTime?>[
      target,
      for (var d = 22; d <= 30; d++) DateTime.utc(2026, 10, d),
    ]) {
      if (date == null) continue;
      try {
        final page = await client.fetchBasket(session, cursor: _jalali(date));
        print('--- basket for ${_iso(date)} '
            '(${page.listings.length} listing(s)) ---');
        for (final listing in page.listings) {
          print('  ${listing.id}  ${listing.slot.name}  '
              '${listing.option.name}  hall=${listing.hall.name}  '
              '[${listing.priceRial}]');
        }
      } catch (e) {
        print('--- basket for ${_iso(date)} FAILED: $e');
      }
    }
  } catch (e, stack) {
    print('FAILED: $e');
    print(stack.toString().split('\n').take(6).join('\n'));
  }
}

/// The Jalali date the buy page's date filter takes.
String _jalali(DateTime d) {
  // The portal's Jalali dates for 2026-10-22 .. 2026-10-25 are known:
  // 1405/08/01 .. 1405/08/04. The conversion is done through the app's own
  // helper so the probe cannot drift from the app.
  final j = toJalali(d);
  return '${j.year}/${j.month.toString().padLeft(2, '0')}/'
      '${j.day.toString().padLeft(2, '0')}';
}

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';
