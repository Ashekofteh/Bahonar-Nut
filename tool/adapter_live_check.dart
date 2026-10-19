/// Live validation of the real adapter against the portal.
///
/// READ-ONLY. Exercises login, server time, balance, offerings, reservations
/// and basket reads through [CullinanPortalClient] — the same code the app
/// uses — and prints what came back. It never reserves, buys, cancels or
/// lists anything.
///
/// Usage: `dart run tool/adapter_live_check.dart <studentId> <password>`
// Diagnostic CLI tool: stdout printing is the entire point.
// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings

library;

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/adapter/cullinan_client.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/transport/http_transport.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run tool/adapter_live_check.dart <studentId> <password>');
    return;
  }
  final username = args[0];
  final password = args[1];

  final transport = PortalTransport(baseUri: Uri.parse('https://nut.uk.ac.ir/'));
  final client = CullinanPortalClient(transport: transport);

  try {
    // --- Login, using the on-device solver ---
    final challenge = await client.beginLogin(username);
    print('1. challenge fetched: ${challenge?.kind.name} '
        '(${challenge?.imageBytes.length} bytes)');

    final solution = CaptchaSolver().solve(challenge!.imageBytes);
    print('   solved: ${solution.text ?? "<declined>"}');
    if (solution.text == null) return;

    final session = await client.completeLogin(
      username: username,
      password: password,
      challenge: LoginChallengeResponse(solution.text!),
    );
    print('2. LOGIN OK - cookies: ${session.cookies.keys.toList()}');

    // --- Server time ---
    final serverTime = await client.fetchServerTime(session);
    print('3. server time: $serverTime');

    // --- Balance ---
    final balance = await client.fetchBalance(session);
    print('4. balance: ${balance.amountRial} Rial');

    // --- Reservations held ---
    final reservations = await client.fetchReservations(session);
    print('5. reservations held: ${reservations.length}');
    for (final r in reservations.take(6)) {
      print('     ${r.date.toIso8601String().substring(0, 10)} '
          '${r.slot.name} ${r.hall.name} ${r.option.name} '
          '(${r.option.priceRial})');
    }

    // --- Offerings for the first reservable day ---
    final target = reservations.isNotEmpty
        ? reservations.first.date
        : DateTime.utc(2026, 10, 19);
    final offerings = await client.fetchOfferings(session, target);
    print('6. offerings on ${target.toIso8601String().substring(0, 10)}: '
        '${offerings.length}');
    for (final o in offerings.take(8)) {
      print('     ${o.slot.name} ${o.hall.name} ${o.option.name} '
          '(${o.option.priceRial}) reservable=${o.reservable}');
    }

    // --- Basket ---
    final basket = await client.fetchBasket(session);
    print('7. basket listings: ${basket.listings.length}');
    for (final l in basket.listings.take(8)) {
      print('     ${l.id}  ${l.option.name} (${l.priceRial}) ${l.hall.name}');
    }
  } catch (e, st) {
    print('FAILED: $e');
    print(st.toString().split('\n').take(6).join('\n'));
  } finally {
    transport.close();
  }
}
