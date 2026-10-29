/// The app's cancel, with the app's **restored** session.
///
/// The device's cancel reported success while the portal kept the meal and
/// the ledger recorded nothing. The same cancel, run from the command line
/// with a **fresh** login, works — so the difference is the session.
///
/// The app restores its session from storage; a probe normally logs in. A
/// restored session's cookies were never a response, so the jar holds them
/// but the portal may have rotated them.
///
/// This runs the app's own client against a restored session and does the
/// real cancel, then re-books the meal if it landed.
///
/// Usage:
///   dart run tool/cancel_restored.dart --session '<cookie json>' <studentId>
///
library;

// One-shot live probe tool: stdout printing is the entire point.
// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings

import 'dart:convert';

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
    print('usage: dart run tool/cancel_restored.dart --session <json> <id>');
    return;
  }
  final user = args[0];

  final clock = SyncedServerClock();
  final transport = PortalTransport(baseUri: Uri.parse(_base), clock: clock);
  final client = CullinanPortalClient(transport: transport);

  try {
    final cookies = restored ??
        (jsonDecode(args.length > 1 ? args[1] : '{}') as Map<String, dynamic>)
            .map((k, v) => MapEntry(k, v.toString()));
    transport.restoreSession(user, cookies);
    final session = Session(
      account: user,
      cookies: cookies,
      establishedAt: DateTime.now().toUtc(),
    );
    print('session: ${cookies['ASP.NET_SessionId']}');

    // The app's order: the table read, then the sync, then the cancel.
    final menus = await client.fetchBookableMenus(session);
    print('menus: ${menus.menus.length}');

    final balance = await client.fetchBalance(session);
    print('credit: ${balance.amountRial}');

    final reservations = await client.fetchReservations(session);
    print('reservations: ${reservations.length}');
    print('target present: '
        '${reservations.any((r) => _isTarget(r.date) && r.slot == MealSlot.breakfast)}');

    // The cancel, exactly as the app calls it: the row's date, stringified.
    print('\n--- the cancel');
    final outcome = await client.cancel(session, MealRef(date: _target, slot: MealSlot.breakfast));
    print('  outcome: $outcome');
    print('  is CancelSucceeded: ${outcome is CancelSucceeded}');

    final after = await client.fetchReservations(session);
    final balanceAfter = await client.fetchBalance(session);
    final ledger = await client.fetchTransactions(session);
    print('\n--- the portal\'s state');
    print('  reservations now: ${after.length}');
    print('  target still held: '
        '${after.any((r) => _isTarget(r.date) && r.slot == MealSlot.breakfast)}');
    print('  credit now: ${balanceAfter.amountRial}');
    print('  transactions now: ${ledger.length}');

    if (outcome is CancelSucceeded &&
        !after.any((r) => _isTarget(r.date) && r.slot == MealSlot.breakfast)) {
      print('\n--- restoring');
      final target = reservations.firstWhere((r) => _isTarget(r.date));
      try {
        await client.reserve(
          session,
          MealOffering(
            date: target.date,
            slot: target.slot,
            hall: target.hall,
            option: target.option,
            reservable: true,
          ),
        );
        print('  re-booked');
      } catch (e) {
        print('  !! re-book threw: $e');
      }
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
