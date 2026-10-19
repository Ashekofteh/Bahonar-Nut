/// READ-ONLY probe: where, if anywhere, do the gendered hall names appear?
///
/// The product owner reports that female accounts see «مرکزی خواهران» and
/// «فنی خواهران» instead of «مرکزی برادران» / «فنی برادران».
///
/// The reservation grid showed the SAME names for both accounts, so this sweeps
/// every page of the portal for both spellings and reports where each appears.
///
/// Usage: `dart run tool/gender_names_probe.dart <studentId> <password>
library;

import 'dart:io';

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/adapter/cullinan_client.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/transport/http_transport.dart';

const _base = 'https://nut.uk.ac.ir/';

const pages = <String>[
  '/',
  '/Reservation/Reservation.aspx',
  '/Reservation/CafeteriaReservation.aspx',
  '/FoodBasket/FoodBasketBuy.aspx',
  '/FoodBasket/FoodBasketSale.aspx',
  '/MyCullinan/MyTransaction.aspx',
  '/Reservation/ForgotReceipt.aspx',
  '/MyCullinan/MyProfile.aspx',
];

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run tool/gender_names_probe.dart <studentId> <password>');
    return;
  }
  final username = args[0];
  final password = args[1];

  final transport = PortalTransport(baseUri: Uri.parse(_base));
  final client = CullinanPortalClient(transport: transport);

  try {
    final challenge = await client.beginLogin(username);
    final answer = CaptchaSolver().solve(challenge!.imageBytes);
    if (!answer.isConfident) {
      print('!! could not read the captcha');
      return;
    }
    await client.completeLogin(
      username: username,
      password: password,
      challenge: LoginChallengeResponse(answer.text!),
    );

    for (final path in pages) {
      try {
        final resp = await transport.get(username, path);
        final body = resp.body;
        final brothers = _count(body, 'برادران');
        final sisters = _count(body, 'خواهران');
        final central = _count(body, 'مرکزی');
        final technical = _count(body, 'فنی');
        print('  ${path.padRight(42)} '
            'برادران=$brothers خواهران=$sisters مرکزی=$central فنی=$technical');
        if (sisters > 0) {
          final i = body.indexOf('خواهران');
          print('      ...${body.substring((i - 90).clamp(0, i), i + 40)}...');
        }
      } catch (e) {
        print('  ${path.padRight(42)} ERROR: $e');
      }
    }
  } catch (e) {
    print('FAILED: $e');
  } finally {
    transport.close();
  }
}

int _count(String haystack, String needle) {
  var count = 0;
  var index = haystack.indexOf(needle);
  while (index >= 0) {
    count++;
    index = haystack.indexOf(needle, index + needle.length);
  }
  return count;
}
