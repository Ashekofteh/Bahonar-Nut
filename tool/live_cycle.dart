/// A live book-and-cancel cycle driven through the app's **own** client.
///
/// The earlier standalone script re-implemented the portal protocol and
/// drifted from it (it over-hopped the week, so its booking landed on a week
/// with no menu). This one uses [CullinanPortalClient] — the same code the
/// app ships — so what it proves is what the app does.
///
/// ## What it does, exactly once
///   1. Logs in, the same way the app does.
///   2. Reads the bookable week through `fetchBookableMenus`.
///   3. Picks the cheapest **bookable** offering whose slot the account does
///      not already hold, and whose price the balance covers.
///   4. Books it with `reserve`.
///   5. Verifies by re-reading: the meal is held and the credit fell by
///      exactly the price.
///   6. Cancels it with `cancel`.
///   7. Verifies again: the meal is gone and the credit came back.
///   8. Verifies the account's **other** meals survived both writes.
///
/// Usage: `dart run tool/live_cycle.dart <studentId> <password>`
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

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run tool/live_cycle.dart <studentId> <password>');
    return;
  }
  final user = args[0];
  final pass = args[1];

  final clock = SyncedServerClock();
  final transport = PortalTransport(baseUri: Uri.parse(_base), clock: clock);
  final client = CullinanPortalClient(transport: transport);

  try {
    // ---------------------------------------------------------- LOGIN
    final page = await transport.get(user, '/');
    final captcha = await transport.getBytes(user, '/UserControls/Captcha.ashx');
    final solution = CaptchaSolver().solve(captcha);
    print('captcha: ${solution.text}');
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
    print('login OK; clock synced = ${clock.isSynced}, portal today = ${clock.portalTodayUtc}');

    // ------------------------------------------------------- BASELINE
    final creditBefore = await client.fetchBalance(session);
    print('credit BEFORE: ${creditBefore.amountRial}');

    final heldBefore = await client.fetchReservations(session);
    final heldKeysBefore = heldBefore.map(_key).toSet();
    print('held BEFORE (${heldBefore.length}): '
        '${heldBefore.map((r) => '${_key(r)} ${r.option.name} @${r.hall.name}').toList()..sort()}');

    // ------------------------------------------------------ THE MENU
    final bookable = await client.fetchBookableMenus(session);
    print('\nbookable dates: '
        '${bookable.dates.map((d) => d.toIso8601String().substring(0, 10)).toList()}');
    print('menus read: ${bookable.menus.length}');
    for (final menu in bookable.menus) {
      print('  ${menu.date.toIso8601String().substring(0, 10)} '
          '${menu.slot.name}: '
          '${menu.dishes.map((d) => '${d.name} (${d.priceRial})').toList()}');
    }

    if (bookable.menus.isEmpty) {
      print('!! no menus; stopping before any write');
      return;
    }

    // ------------------------------------------------------ THE TARGET
    // The cheapest offering that is (a) reservable, (b) affordable, and
    // (c) not already held for that slot — the portal enforces none of
    // these, so the app's own service does, and this tool borrows the
    // same rules.
    final heldSlots = <String>{
      for (final r in heldBefore) '${_dateKey(r.date)}|${r.slot.name}',
    };

    MealOffering? target;
    var cheapest = 1 << 30;
    for (final menu in bookable.menus) {
      if (!menu.reservable) continue;
      if (heldSlots.contains('${_dateKey(menu.date)}|${menu.slot.name}')) {
        continue;
      }
      for (final dish in menu.dishes) {
        if (dish.priceRial > creditBefore.amountRial) continue;
        if (dish.priceRial >= cheapest) continue;
        cheapest = dish.priceRial;
        target = MealOffering(
          date: menu.date,
          slot: menu.slot,
          option: dish,
          hall: menu.halls.isNotEmpty
              ? menu.halls.first
              : const Hall(id: '1', name: ''),
          reservable: true,
        );
      }
    }

    if (target == null) {
      print('!! no affordable, unheld, reservable offering; stopping');
      print('   credit=${creditBefore.amountRial}');
      return;
    }
    print('\nTARGET: ${_dateKey(target.date)} ${target.slot.name} '
        '${target.option.name} (${target.option.priceRial} Rial) '
        'hall=${target.hall.name}');

    // ------------------------------------------------------------ BOOK
    print('\n--- BOOK ---');
    try {
      final reservation = await client.reserve(session, target);
      print('reserve() returned: ${_key(reservation)} '
          '${reservation.option.name} @${reservation.hall.name}');
    } catch (e) {
      print('!! reserve() threw: $e');
      return;
    }

    // ---------------------------------------------------------- VERIFY
    final creditAfterBook = await client.fetchBalance(session);
    final heldAfterBook = await client.fetchReservations(session);
    final heldKeysAfterBook = heldAfterBook.map(_key).toSet();
    final targetKey = '${_dateKey(target.date)}|${target.slot.name}';

    print('credit AFTER book: ${creditAfterBook.amountRial} '
        '(expected ${creditBefore.amountRial - target.option.priceRial})');
    print('target held = ${heldKeysAfterBook.contains(targetKey)}');
    print('other meals lost = '
        '${heldKeysBefore.difference(heldKeysAfterBook).toList()}');

    if (!heldKeysAfterBook.contains(targetKey)) {
      print('!! booking did not take; NOT attempting a cancel');
      return;
    }
    if (heldKeysBefore.difference(heldKeysAfterBook).isNotEmpty) {
      print('!! other meals were disturbed; stopping before the cancel');
      return;
    }

    // ---------------------------------------------------------- CANCEL
    print('\n--- CANCEL ---');
    try {
      final outcome =
          await client.cancel(session, MealRef(date: target.date, slot: target.slot));
      print('cancel() outcome: $outcome');
    } catch (e) {
      print('!! cancel() threw: $e');
      return;
    }

    // ---------------------------------------------------------- VERIFY
    final creditAfterCancel = await client.fetchBalance(session);
    final heldAfterCancel = await client.fetchReservations(session);
    final heldKeysAfterCancel = heldAfterCancel.map(_key).toSet();

    print('\ncredit AFTER cancel: ${creditAfterCancel.amountRial} '
        '(expected ${creditBefore.amountRial})');
    print('target still held = ${heldKeysAfterCancel.contains(targetKey)} '
        '(expected false)');
    print('other meals lost = '
        '${heldKeysBefore.difference(heldKeysAfterCancel).toList()}');
    print('\n=== SUMMARY ===');
    print('booked : ${heldKeysAfterBook.contains(targetKey)}');
    print('credit moved by booking: '
        '${creditBefore.amountRial - creditAfterBook.amountRial}');
    print('credit restored by cancel: '
        '${creditAfterCancel.amountRial - creditAfterBook.amountRial}');
    print('collateral damage: '
        '${heldKeysBefore.difference(heldKeysAfterCancel).toList()}');
  } catch (e, st) {
    print('EXCEPTION: $e');
    print(st.toString().split('\n').take(6).join('\n'));
  } finally {
    transport.close();
  }
}

String _key(Reservation r) => '${_dateKey(r.date)}|${r.slot.name}';

String _dateKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String _input(String html, String id) {
  final m = RegExp('id="' + RegExp.escape(id) + r'"[^>]*value="([^"]*)"')
      .firstMatch(html);
  return m?.group(1) ?? '';
}
