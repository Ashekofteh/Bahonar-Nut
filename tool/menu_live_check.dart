/// Live read-only probe: log in to the portal, then read the **weekly menu**
/// through the app's own client and parser, and print the halls and dishes it
/// finds for each meal slot.
///
/// READ-ONLY. This script performs no reservation, purchase, cancellation, or
/// top-up. Those write paths are deliberately absent.
///
/// Usage: `dart run tool/menu_live_check.dart <studentId> <password> [date]`
///
/// The credentials are taken from argv and never written to disk or logged.
/// The `date` is an ISO date (default: today) and may name a date in the next
/// week, which is reached by the menu's own "next week" postback.
library;

import 'dart:io';

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/adapter/cullinan_client.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/transport/http_transport.dart';

const _base = 'https://nut.uk.ac.ir/';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln(
      'usage: dart run tool/menu_live_check.dart <studentId> <password> [date]',
    );
    exitCode = 2;
    return;
  }
  final username = args[0];
  final password = args[1];
  final target = args.length > 2
      ? DateTime.parse(args[2])
      : DateTime.now();

  final transport = PortalTransport(baseUri: Uri.parse(_base));
  final client = CullinanPortalClient(transport: transport);

  try {
    // --- Step 1: begin the login (page + challenge, bound together) ---
    final challenge = await client.beginLogin(username);
    if (challenge == null) {
      stdout.writeln('1. no challenge issued');
      return;
    }
    stdout.writeln('1. challenge fetched (${challenge.imageBytes.length} bytes)');

    // --- Step 2: solve it locally ---
    final solver = CaptchaSolver();
    final solution = solver.solve(challenge.imageBytes);
    stdout.writeln(
      '2. solved: ${solution.text ?? "<declined>"} '
      '(confidence ${solution.confidence.toStringAsFixed(3)})',
    );
    if (solution.text == null) {
      stdout.writeln('   solver declined; would fall back to asking the user');
      return;
    }

    // --- Step 3: complete the login ---
    final session = await client.completeLogin(
      username: username,
      password: password,
      challenge: LoginChallengeResponse(solution.text!),
    );
    stdout.writeln('3. LOGIN OK (session established at ${session.establishedAt})');

    // --- Step 4: read the weekly menu through the app's own code ---
    final menus = await client.fetchMenu(session, target);
    stdout.writeln('4. menu read for ${_iso(target)}: ${menus.length} meal(s)');
    stdout.writeln('');

    for (final menu in menus) {
      stdout.writeln('--- ${menu.slot.name} on ${_iso(menu.date)} '
          '(reservable: ${menu.reservable}) ---');
      stdout.writeln('  halls (${menu.halls.length}):');
      for (final hall in menu.halls) {
        stdout.writeln('    - id=${hall.id}  ${hall.name}');
      }
      stdout.writeln('  dishes (${menu.dishes.length}):');
      for (final dish in menu.dishes) {
        stdout.writeln('    - id=${dish.id}  ${dish.name}  '
            '[${dish.priceRial} ریال]');
      }
      stdout.writeln('');
    }

    if (menus.isEmpty) {
      stdout.writeln('   (no menu found — the date may be in neither week, '
          'or the portal may not serve it)');
    }
  } catch (e, stack) {
    stdout.writeln('FAILED: $e');
    stderr.writeln(stack.toString());
    exitCode = 1;
  }
}

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';
