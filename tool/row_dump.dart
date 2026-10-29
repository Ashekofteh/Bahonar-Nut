/// READ-ONLY: dump the target row from the portal's week-2 page.
///
/// The app's cancel read-back said the meal was gone; the portal still
/// holds it. This prints the raw row so the two can be compared.
///
/// Usage: `dart run tool/row_dump.dart <studentId> <password> [date] [slot]`
library;

// One-shot live probe tool: stdout printing is the entire point.
// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/adapter/cullinan_client.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/core/persian.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:bahonar_nut/transport/html_parsing.dart';
import 'package:bahonar_nut/transport/http_transport.dart';

const _base = 'https://nut.uk.ac.ir/';

Future<void> main(List<String> args) async {
  final user = args[0];
  final pass = args[1];
  final target = args.length > 2
      ? DateTime.utc(
          int.parse(args[2].split('-')[0]),
          int.parse(args[2].split('-')[1]),
          int.parse(args[2].split('-')[2]),
        )
      : DateTime.utc(2026, 10, 25);
  final slotName = args.length > 3 ? args[3] : 'breakfast';

  final clock = SyncedServerClock();
  final transport = PortalTransport(baseUri: Uri.parse(_base), clock: clock);
  final client = CullinanPortalClient(transport: transport);

  try {
    final challenge = await client.beginLogin(user);
    if (challenge != null) {
      final answer = CaptchaSolver().solve(
        await transport.getBytes(user, '/UserControls/Captcha.ashx'),
      );
      await client.completeLogin(
        username: user,
        password: pass,
        challenge: LoginChallengeResponse(answer.text!),
      );
    }
    final session = Session(
      account: user,
      cookies: transport.jars.jarFor(user).cookies,
      establishedAt: DateTime.now().toUtc(),
    );

    const path = '/Reservation/Reservation.aspx';
    final current = await transport.get(session.account, path);
    final next = await transport.post(
      session.account,
      path,
      body: {
        '__VIEWSTATE': hiddenFieldValue(current.body, '__VIEWSTATE'),
        '__VIEWSTATEGENERATOR':
            hiddenFieldValue(current.body, '__VIEWSTATEGENERATOR'),
        '__EVENTTARGET': 'ctl00\$cphMain\$imgbtnNextWeek',
        '__EVENTARGUMENT': '',
      },
    );

    final grid = switch (MealSlot.values.firstWhere((s) => s.name == slotName)) {
      MealSlot.breakfast => 'grdReservationBreakfast',
      MealSlot.lunch => 'grdReservationLunch',
      MealSlot.dinner => 'grdReservationDinner',
    };

    print('grid: $grid');
    final rows = tableRows(next.body, grid);
    print('rows: ${rows.length}');
    for (final row in rows) {
      final date = parseJalaliDate(row.cell(1));
      final isTarget = date != null &&
          date.year == target.year &&
          date.month == target.month &&
          date.day == target.day;
      final status = rowStatus(row.raw);
      final checkbox = inputBySuffix(row.raw, 'chkReserve');
      print('---');
      print('  cells=${row.cells.length} date=${row.cell(1)} '
          'parsed=${date?.toIso8601String().substring(0, 10)} '
          'target=$isTarget');
      print('  cell(6)=${row.cell(6)} status(held=${status.held},'
          'locked=${status.locked})');
      print('  checkbox: ${checkbox == null ? 'null' : '${checkbox.name} '
          'checked=${checkbox.checked} disabled=${checkbox.disabled}'}');
      if (isTarget) {
        print('  RAW: ${row.raw}');
      }
    }
  } catch (e, st) {
    print('EXCEPTION: $e');
    print(st.toString().split('\n').take(8).join('\n'));
  } finally {
    transport.close();
  }
}
