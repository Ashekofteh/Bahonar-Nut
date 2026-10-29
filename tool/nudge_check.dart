/// READ-ONLY probe: does the next-week nudge see the meals of the week it
/// checks?
///
/// The nudge checks the **coming** week — the one that begins at the coming
/// Saturday. On 2026-10-21 (a Wednesday) that week is 2026-10-24..30, which
/// is the portal's *second* week page. A read that stopped at the current
/// week could not have contained any of it.
///
/// So this runs the nudge twice: once against a one-week read, once against
/// the two-week read the app now does, and reports the gaps each produces.
///
/// Usage: `dart run tool/nudge_check.dart <studentId> <password>`
library;

// One-shot live probe tool: stdout printing is the entire point.
// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/adapter/cullinan_client.dart';
import 'package:bahonar_nut/adapter/cullinan_parser.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/next_week.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:bahonar_nut/transport/http_transport.dart';

const _base = 'https://nut.uk.ac.ir/';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run tool/nudge_check.dart <studentId> <password>');
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

    // What the app reads now: both weeks.
    final both = await client.fetchReservations(session);
    print('\ntwo-week read: ${both.length} reservation(s)');
    for (final r in both) {
      print('   ${_d(r.date)} ${r.slot.name}');
    }

    // What the app used to read: the current week only.
    final current = await transport.get(user, '/Reservation/Reservation.aspx');
    final oneWeek = CullinanParser.parseReservations(current.body);
    print('\none-week read: ${oneWeek.length} reservation(s)');

    final weekStart = nextWeekStart(clock.portalTodayUtc);
    print('\ncoming week: ${_d(weekStart)} .. '
        '${_d(DateTime.utc(weekStart.year, weekStart.month, weekStart.day + 6))}');

    // The nudge, as the reminder would run it.
    final twoWeekStatus = detectNextWeekGaps(
      weekStart: weekStart,
      reservationsByAccount: {user: both},
      clock: clock,
    );
    final oneWeekStatus = detectNextWeekGaps(
      weekStart: weekStart,
      reservationsByAccount: {user: oneWeek},
      clock: clock,
    );

    print('\nnudge from the ONE-week read: ${twoWeekStatus.gaps.length} gap(s)');
    for (final gap in oneWeekStatus.gaps) {
      print('   ${_d(gap.date)} ${gap.slot.name}');
    }
    print('nudge from the TWO-week read: ${twoWeekStatus.gaps.length} gap(s)');
    for (final gap in twoWeekStatus.gaps) {
      print('   ${_d(gap.date)} ${gap.slot.name}');
    }
  } catch (e, st) {
    print('EXCEPTION: $e');
    print(st.toString().split('\n').take(8).join('\n'));
  } finally {
    transport.close();
  }
}

String _d(DateTime date) => date.toIso8601String().substring(0, 10);

String _input(String html, String id) {
  final m = RegExp('id="' + RegExp.escape(id) + r'"[^>]*value="([^"]*)"')
      .firstMatch(html);
  return m?.group(1) ?? '';
}
