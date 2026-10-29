/// A complete book-and-cancel cycle, through the app's **own** client, ending
/// in the state it started in.
///
/// ## Why this shape
///
/// The live cycle could not run to completion: the account's balance was
/// 75,000 Rial and the cheapest meal is 150,000 Rial, so there was nothing
/// affordable to book. But the account **does** hold a meal it could give
/// back — a breakfast on 1405/08/03 (2026-10-25), which the portal still
/// holds and which is still before its cutoff.
///
/// So this cycle uses that meal as the seed:
///
///   1. Cancel it. The portal releases it and refunds the 150,000 Rial, so
///      the balance rises to 225,000 Rial.
///   2. Book a breakfast again — the same slot, so the account ends in the
///      state it started in.
///   3. Cancel **that** one too, so the book-then-cancel pair is exercised
///      on a meal this cycle booked itself.
///   4. Book it a final time, so the student still has the breakfast.
///
/// The end state is identical to the start: the same meal, held, on the same
/// date, in the same hall.
////
/// Every step is verified against the **portal**, not against the app's own
/// bookkeeping. The portal is the authority on what is held and on what the
/// balance is.
///
/// Usage: `dart run tool/cycle_net_zero.dart <studentId> <password>`
library;

// One-shot live action tool: stdout printing is the entire point.
// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/adapter/cullinan_client.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:bahonar_nut/transport/http_transport.dart';

const _base = 'https://nut.uk.ac.ir/';

/// The seed meal: a breakfast the account holds and can still give back.
const _seedDate = '2026-10-25';
const _seedSlot = MealSlot.breakfast;

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run tool/cycle_net_zero.dart <studentId> <password>');
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
    print('login OK; portal today = ${clock.portalTodayUtc}');

    // ---------------------------------------------------------- THE STATE
    final seedDate = DateTime.parse('${_seedDate}T00:00:00Z');
    final startBalance = await client.fetchBalance(session);
    final startHeld = await client.fetchReservations(session);
    print('\nSTART: credit=${startBalance.amountRial}  '
        'held=${startHeld.length}');
    for (final r in startHeld) {
      print('   ${_d(r.date)} ${r.slot.name} ${r.option.name} '
          '@${r.hall.name} (${r.option.priceRial})');
    }

    final seed = startHeld.where((r) =>
        _d(r.date) == _seedDate && r.slot == _seedSlot);
    if (seed.isEmpty) {
      print('!! the seed meal is not held; nothing to do');
      return;
    }
    final seedReservation = seed.first;
    print('\nseed: ${_d(seedReservation.date)} ${seedReservation.slot.name} '
        '${seedReservation.option.name} '
        '(option ${seedReservation.option.id}) '
        '@${seedReservation.hall.name}');

    // ------------------------------------------------- STEP 1: CANCEL IT
    print('\n--- STEP 1: cancel the seed meal ---');
    final cancel1 = await client.cancel(
      session,
      MealRef(date: seedReservation.date, slot: seedReservation.slot),
    );
    print('cancel() outcome: $cancel1');

    final afterCancel1 = await client.fetchReservations(session);
    final balanceAfterCancel1 = await client.fetchBalance(session);
    final stillHeld = afterCancel1.any((r) =>
        _d(r.date) == _seedDate && r.slot == _seedSlot);
    print('portal still holds it: $stillHeld');
    print('credit now: ${balanceAfterCancel1.amountRial} '
        '(was ${startBalance.amountRial})');

    if (!stillHeld) {
      print('\n*** CANCEL SUCCESS VERIFIED against the portal ***');
      print('refund = ${balanceAfterCancel1.amountRial - startBalance.amountRial}');
    } else {
      print('\n!! the cancel did not take; stopping before any booking');
      return;
    }

    // --------------------------------------------------- STEP 2: BOOK IT
    print('\n--- STEP 2: book the same breakfast again ---');
    final offering = MealOffering(
      date: seedReservation.date,
      slot: seedReservation.slot,
      hall: seedReservation.hall,
      option: seedReservation.option,
      reservable: true,
    );
    try {
      final booked = await client.reserve(session, offering);
      print('reserve() returned: ${_d(booked.date)} ${booked.slot.name} '
          '${booked.option.name} @${booked.hall.name}');
    } catch (e) {
      print('!! reserve() threw: $e');
      print('   the account now holds nothing for that slot; the student '
          'should re-book it from the app');
      return;
    }

    final afterBook = await client.fetchReservations(session);
    final balanceAfterBook = await client.fetchBalance(session);
    final bookedHeld = afterBook.any((r) =>
        _d(r.date) == _seedDate && r.slot == _seedSlot);
    print('portal holds it: $bookedHeld');
    print('credit now: ${balanceAfterBook.amountRial}');
    if (!bookedHeld) {
      print('!! the booking did not land; stopping');
      return;
    }

    // ------------------------------------------------ STEP 3: CANCEL IT
    print('\n--- STEP 3: cancel the meal this cycle booked ---');
    final cancel2 = await client.cancel(
      session,
      MealRef(date: seedReservation.date, slot: seedReservation.slot),
    );
    print('cancel() outcome: $cancel2');

    final afterCancel2 = await client.fetchReservations(session);
    final balanceAfterCancel2 = await client.fetchBalance(session);
    final heldAfterCancel2 = afterCancel2.any((r) =>
        _d(r.date) == _seedDate && r.slot == _seedSlot);
    print('portal still holds it: $heldAfterCancel2');
    print('credit now: ${balanceAfterCancel2.amountRial}');

    // ----------------------------------------------- STEP 4: BOOK AGAIN
    print('\n--- STEP 4: book it back, so the student keeps the breakfast ---');
    try {
      final booked = await client.reserve(session, offering);
      print('reserve() returned: ${_d(booked.date)} ${booked.slot.name} '
          '${booked.option.name}');
    } catch (e) {
      print('!! reserve() threw: $e');
    }

    final finalHeld = await client.fetchReservations(session);
    final finalBalance = await client.fetchBalance(session);
    final finalHas = finalHeld.any((r) =>
        _d(r.date) == _seedDate && r.slot == _seedSlot);

    print('\n=== SUMMARY ===');
    print('cancel of an existing meal took:    ${cancel1 is CancelSucceeded}');
    print('book took:                           true');
    print('cancel of a meal this cycle booked:  ${cancel2 is CancelSucceeded}');
    print('the meal is held again:              $finalHas');
    print('held count: ${startHeld.length} -> ${finalHeld.length}');
    print('credit: ${startBalance.amountRial} -> ${finalBalance.amountRial}');
    print('net change in credit: '
        '${finalBalance.amountRial - startBalance.amountRial}');
    print('other meals lost: '
        '${_lost(startHeld, finalHeld).join(", ")}');
  } catch (e, st) {
    print('EXCEPTION: $e');
    print(st.toString().split('\n').take(8).join('\n'));
  } finally {
    transport.close();
  }
}

/// The meals that were held at the start and are not held now.
List<String> _lost(List<Reservation> before, List<Reservation> after) {
  final now = after.map((r) => '${_d(r.date)}|${r.slot.name}').toSet();
  return [
    for (final r in before)
      if (!now.contains('${_d(r.date)}|${r.slot.name}'))
        '${_d(r.date)} ${r.slot.name}',
  ];
}

String _d(DateTime date) => date.toIso8601String().substring(0, 10);

String _input(String html, String id) {
  final m = RegExp('id="' + RegExp.escape(id) + r'"[^>]*value="([^"]*)"')
      .firstMatch(html);
  return m?.group(1) ?? '';
}
