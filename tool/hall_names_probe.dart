/// READ-ONLY probe: what do the halls look like for each account?
///
/// The product owner reports that female accounts see the halls as
/// «مرکزی خواهران» / «فنی خواهران» rather than «مرکزی برادران» /
/// «فنی برادران».
///
/// The question that decides the data model: do the hall *identifiers* also
/// change, or only the *names*? If the ids are stable (1 = central, 2 =
/// engineering) then the app must key on the ids and take the display name
/// from the portal, rather than matching Persian strings.
///
/// Usage: `dart run tool/hall_names_probe.dart <studentId> <password>
library;

import 'dart:io';

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/adapter/cullinan_client.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/transport/http_transport.dart';

const _base = 'https://nut.uk.ac.ir/';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run tool/hall_names_probe.dart <studentId> <password>');
    return;
  }
  final username = args[0];
  final password = args[1];

  final transport = PortalTransport(baseUri: Uri.parse(_base));
  final client = CullinanPortalClient(transport: transport);

  try {
    // The login must be the full sequence: fetch the page, fetch the
    // challenge, then answer it. completeLogin alone does not fetch the
    // challenge, so the answer never matches.
    final challenge = await client.beginLogin(username);
    final answer = CaptchaSolver().solve(challenge!.imageBytes);
    if (!answer.isConfident) {
      print('!! could not read the captcha: ${answer.text}');
      return;
    }
    print('captcha read: ${answer.text}');
    final session = await client.completeLogin(
      username: username,
      password: password,
      challenge: LoginChallengeResponse(answer.text!),
    );

    final page = await transport.get(username, '/Reservation/Reservation.aspx');
    final body = page.body;

    print('=== profile ===');
    print('  name  : ${_textById(body, 'divUsername')}');
    print('  id    : ${_textById(body, 'lblIdNumber')}');
    print('  credit: ${_label(body, 'lblCredit')}');
    print('  week  : ${_textById(body, 'cphMain_lblWeekDate')}');

    print('\n=== hall dropdown options, per grid (id -> name) ===');
    for (final grid in [
      'grdReservationBreakfast',
      'grdReservationLunch',
      'grdReservationDinner',
    ]) {
      final t = RegExp('<table[^>]*id="[^"]*' + grid + '"[^>]*>(.*?)</table>',
              dotAll: true)
          .firstMatch(body);
      if (t == null) continue;
      final seen = <String, String>{};
      for (final sel in RegExp(r'<select[^>]*name="([^"]*drpSelf)"[^>]*>(.*?)</select>',
              dotAll: true)
          .allMatches(t.group(1)!)) {
        for (final o in RegExp(r'<option[^>]*value="([^"]*)"[^>]*>(.*?)</option>',
                dotAll: true)
            .allMatches(sel.group(2)!)) {
          seen[o.group(1)!] = o.group(2)!.trim();
        }
      }
      print('  $grid: $seen');
    }

    print('\n=== the DAILY CAFETERIA hall picker (a different hall set) ===');
    final caf =
        await transport.get(username, '/Reservation/CafeteriaReservation.aspx');
    for (final m in RegExp(
            r'<select[^>]*name="([^"]*drpSelfTitle[^"]*)"[^>]*>(.*?)</select>',
            dotAll: true)
        .allMatches(caf.body)) {
      final opts = RegExp(r'<option[^>]*value="([^"]*)"[^>]*>(.*?)</option>',
              dotAll: true)
          .allMatches(m.group(2)!);
      final names = <String>[];
      for (final o in opts) {
        final text = o.group(2)!
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        names.add('${o.group(1)}=$text');
      }
      print('  ${m.group(1)}: $names');
    }

    print('\n=== the officially offered dishes, per slot, for a future date ===');
    // The next week's Thursday, which is editable and has a published menu.
    for (final date in ['2026-10-22', '2026-10-23', '2026-10-24']) {
      final parsed = DateTime.parse(date);
      final offerings = await client.fetchOfferings(session, parsed);
      if (offerings.isEmpty) {
        print('  $date: (no offerings)');
        continue;
      }
      print('  $date:');
      for (final slot in ['breakfast', 'lunch', 'dinner']) {
        final inSlot = offerings.where((o) => o.slot.name == slot).toList();
        if (inSlot.isEmpty) continue;
        print('    $slot:');
        for (final o in inSlot) {
          print('      id=${o.option.id} hall=${o.hall.id}:${o.hall.name} '
              'price=${o.option.priceRial} name=${o.option.name}');
        }
      }
    }
  } catch (e) {
    print('FAILED: $e');
  } finally {
    transport.close();
  }
}

String _textById(String html, String id) {
  final m = RegExp('id="[^"]*' + RegExp.escape(id) + r'"[^>]*>(.*?)<', dotAll: true)
      .firstMatch(html);
  return m?.group(1)?.replaceAll(RegExp(r'\s+'), ' ').trim() ?? '-';
}

String? _label(String html, String id) {
  final m = RegExp('<label[^>]*id="' + RegExp.escape(id) + r'"[^>]*>(.*?)</label>',
          dotAll: true)
      .firstMatch(html);
  final t = m?.group(1)?.replaceAll(RegExp(r'\s+'), ' ').trim();
  return (t == null || t.isEmpty) ? null : t;
}
