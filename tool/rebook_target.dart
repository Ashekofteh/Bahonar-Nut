/// Re-books the 2026-10-25 breakfast, restoring the seven-meal state.
///
/// The device's cancel removed the meal from the local mirror while the
/// portal kept it; the probes then cancelled and re-booked it several
/// times, so the account is currently on six meals. This puts it back, so
/// the device test has something to cancel.
///
/// Usage:
///   dart run tool/rebook_target.dart <studentId> <password> [optionId]
///   dart run tool/rebook_target.dart --session '<cookie json>' <studentId>
library;

// One-shot live probe tool: stdout printing is the entire point.
// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings

import 'dart:convert';

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/adapter/cullinan_client.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:bahonar_nut/transport/http_transport.dart';

const _base = 'https://nut.uk.ac.ir/';

final _target = DateTime.utc(2026, 10, 25);

Future<void> main(List<String> argv) async {
  var args = argv;
  Map<String, String>? restored;
  if (args.isNotEmpty && args.first == '--session') {
    restored = (jsonDecode(args[1]) as Map<String, dynamic>)
        .map((k, v) => MapEntry(k, v.toString()));
    args = args.sublist(2);
  }
  if (args.isEmpty) {
    print('usage: dart run tool/rebook_target.dart <studentId> <password>');
    return;
  }
  final user = args[0];
  final pass = args.length > 1 && !args[1].startsWith('{') ? args[1] : null;

  final clock = SyncedServerClock();
  final transport = PortalTransport(baseUri: Uri.parse(_base), clock: clock);
  final client = CullinanPortalClient(transport: transport);

  try {
    Map<String, String> cookies;
    if (restored != null) {
      cookies = restored;
      transport.restoreSession(user, cookies);
    } else {
      final challenge = await client.beginLogin(user);
      if (challenge != null) {
        final answer = CaptchaSolver().solve(
          await transport.getBytes(user, '/UserControls/Captcha.ashx'),
        );
        await client.completeLogin(
          username: user,
          password: pass!,
          challenge: LoginChallengeResponse(answer.text!),
        );
      }
      cookies = transport.jars.jarFor(user).cookies;
    }
    final session = Session(
      account: user,
      cookies: cookies,
      establishedAt: DateTime.now().toUtc(),
    );

    final before = await client.fetchReservations(session);
    print('reservations before: ${before.length}');
    for (final r in before) {
      print('  ${_d(r.date)} ${r.slot.name} ${r.option.id} ${r.option.name}');
    }

    final held = before.any((r) => _isTarget(r.date) && r.slot == MealSlot.breakfast);
    if (held) {
      print('\nthe target is already held — nothing to do');
      return;
    }

    // The option id for the target's breakfast, read from the menu.
    final menus = await client.fetchMenu(session, _target);
    final breakfast = menus
        .where((m) => m.slot == MealSlot.breakfast)
        .firstOrNull;
    if (breakfast == null) {
      print('\nno breakfast menu for the target date');
      return;
    }
    print('\nbreakfast menu: '
        '${breakfast.halls.map((h) => "${h.id}:${h.name}").join(", ")}');
    for (final d in breakfast.dishes) {
      print('  option ${d.id}  ${d.name}  ${d.priceRial}');
    }

    final option = breakfast.dishes.first;
    final hall = breakfast.halls.first;

    final reservation = await client.reserve(
      session,
      MealOffering(
        date: _target,
        slot: MealSlot.breakfast,
        hall: hall,
        option: option,
        reservable: true,
      ),
    );
    print('\nre-booked: ${reservation.date} ${reservation.slot.name} '
        '${reservation.option.name}');

    final after = await client.fetchReservations(session);
    final balance = await client.fetchBalance(session);
    print('reservations after: ${after.length}');
    print('credit: ${balance.amountRial}');
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
