/// READ-ONLY audit: what the portal holds, in each week, and what the app's
/// own read path sees.
///
/// This exists because a next-week meal appeared in a capture but not in the
/// app's reservation list. Two things have to be told apart:
///
///   * the portal really holds it, and the app's read misses it — a **read
///     bug** in the app;
///   * the portal no longer holds it, and the capture is stale — nothing to
///     fix.
///
/// So this walks the weeks forward, reads each grid, and reports the rows the
/// portal marks as held, and separately what the app's `fetchReservations`
/// returns. It writes nothing to the account.
///
/// Usage: `dart run tool/week_audit.dart <studentId> <password>`
library;

// One-shot live probe tool: stdout printing is the entire point.
// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/adapter/cullinan_client.dart';
import 'package:bahonar_nut/adapter/cullinan_parser.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/persian.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:bahonar_nut/transport/html_parsing.dart';
import 'package:bahonar_nut/transport/http_transport.dart';

const _base = 'https://nut.uk.ac.ir/';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run tool/week_audit.dart <studentId> <password>');
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

    // ---- What the APP's read path returns (current week only) -------------
    final appRead = await client.fetchReservations(session);
    print('\napp fetchReservations() -> ${appRead.length}');
    for (final r in appRead) {
      print('   ${_d(r.date)} ${r.slot.name} ${r.option.name}');
    }

    // ---- What the PORTAL holds, week by week -------------------------------
    print('\nwalking the weeks forward:');
    var html = login.body;
    final seen = <String>{};
    for (var week = 0; week <= 2; week++) {
      final weekLabel = _byId(html, 'cphMain_lblWeekDate') ?? 'week $week';
      print('\n  WEEK $week  ($weekLabel)');

      var heldHere = 0;
      for (final slot in CullinanParser.reservationSlots) {
        final grid = switch (slot) {
          MealSlot.breakfast => 'grdReservationBreakfast',
          MealSlot.lunch => 'grdReservationLunch',
          MealSlot.dinner => 'grdReservationDinner',
        };
        for (final row in tableRows(html, grid)) {
          if (row.cells.length < 7) continue;
          final date = parseJalaliDate(row.cell(1));
          if (date == null) continue;
          final checkbox = inputBySuffix(row.raw, 'chkReserve');
          if (checkbox == null || !checkbox.checked) continue;

          // "checked" is not "held" (F13): a genuinely held row also carries
          // the green icon and a non-zero amount.
          final amount = _amount(row.cell(6));
          final held = amount > 0;
          if (held) {
            heldHere++;
            final key = '${_d(date)}|${slot.name}';
            final dup = seen.contains(key);
            seen.add(key);
            print('   HELD  $key  amount=$amount'
                '${dup ? '   <== ALSO SEEN EARLIER' : ''}'
                '   "${_text(row.cell(1))}"');
          } else {
            print('   echo  ${_d(date)}|${slot.name}  (checked, no amount)');
          }
        }
      }
      print('   -> $heldHere held row(s) in this week');

      final next = await transport.post(
        user,
        '/Reservation/Reservation.aspx',
        body: {
          '__VIEWSTATE': _input(html, '__VIEWSTATE'),
          '__VIEWSTATEGENERATOR': _input(html, '__VIEWSTATEGENERATOR'),
          '__EVENTTARGET': 'ctl00\$cphMain\$imgbtnNextWeek',
          '__EVENTARGUMENT': '',
        },
      );
      html = next.body;
    }

    // ---- And the balance ---------------------------------------------------
    final balance = await client.fetchBalance(session);
    print('\ncredit: ${balance.amountRial} Rial');

    // ---- The ledger, which is the app's second source of held meals -------
    final transactions = await client.fetchTransactions(session);
    print('\nledger: ${transactions.length} transaction(s)');
    for (final t in transactions) {
      final parsed = parseJalaliDate(t.date);
      print('   ${t.date}  ${t.slot?.name ?? '-'}  ${t.amountRial}  '
          'acq=${t.isAcquisition}  type="${t.type}"  "${t.foodName}"'
          '${parsed == null ? '' : '  -> ${_d(parsed)}'}');
    }
  } catch (e, st) {
    print('EXCEPTION: $e');
    print(st.toString().split('\n').take(8).join('\n'));
  } finally {
    transport.close();
  }
}

/// The amount cell, read as an integer. The portal writes it as bare digits.
int _amount(String cell) {
  final digits = RegExp(r'\d[\d,٬]*').firstMatch(cell)?.group(0) ?? '';
  return int.tryParse(digits.replaceAll(RegExp(r'[^\d]'), '')) ?? 0;
}

String _text(String html) => html
    .replaceAll(RegExp(r'<[^>]*>'), ' ')
    .replaceAll('&nbsp;', ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String _d(DateTime date) => date.toIso8601String().substring(0, 10);

String _input(String html, String id) {
  final m = RegExp('id="' + RegExp.escape(id) + r'"[^>]*value="([^"]*)"')
      .firstMatch(html);
  return m?.group(1) ?? '';
}

String? _byId(String html, String id) {
  final m = RegExp('id="[^"]*' + RegExp.escape(id) + r'"[^>]*>(.*?)<',
          dotAll: true)
      .firstMatch(html);
  final t = m?.group(1)?.replaceAll(RegExp(r'\s+'), ' ').trim();
  return (t == null || t.isEmpty) ? null : t;
}
