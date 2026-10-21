/// Measures how often the on-device solver reads the portal's CAPTCHA.
///
/// READ-ONLY: it only fetches the CAPTCHA image and reads it locally.
///
/// ## Why
///
/// The fallback the student sees is only reached when the solver declines,
/// so the decline rate is the rate at which the app asks a human. A rate
/// that is much higher than the solver's claimed accuracy means the images
/// have changed, and the app would be asking the student on most logins.
///
/// The confidence margin is printed too, because a decline is a *margin*
/// below the threshold — not a misread.
///
/// Usage: `dart run tool/_solver_rate_probe.dart <studentId> [count>`
// Diagnostic CLI tool: stdout printing is the entire point.
// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings

library;

import 'dart:io';

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/transport/http_transport.dart';

const _base = 'https://nut.uk.ac.ir/';

Future<void> main(List<String> args) async {
  if (args.length < 1) {
    print('usage: dart run tool/_solver_rate_probe.dart <id> [count]');
    return;
  }
  final user = args[0];
  final count = args.length > 1 ? int.parse(args[1]) : 20;

  final transport = PortalTransport(baseUri: Uri.parse(_base));
  final solver = CaptchaSolver();
  var read = 0;
  var declined = 0;
  final confidences = <double>[];

  try {
    for (var i = 0; i < count; i++) {
      await transport.get(user, '/');
      final image = await transport.getBytes(user, '/UserControls/Captcha.ashx');
      final solution = solver.solve(image);
      confidences.add(solution.confidence);
      if (solution.text == null) {
        declined++;
        print('${(i + 1).toString().padLeft(3)}: DECLINED  '
            'confidence ${solution.confidence.toStringAsFixed(4)}  '
            '(${image.length} bytes)');
      } else {
        read++;
        print('${(i + 1).toString().padLeft(3)}: read ${solution.text}  '
            'confidence ${solution.confidence.toStringAsFixed(4)}  '
            '(${image.length} bytes)');
      }
    }
  } catch (e, st) {
    print('EXCEPTION: $e');
    print(st.toString().split('\n').take(6).join('\n'));
  } finally {
    transport.close();
  }

  print('\nread $read, declined $declined, of $count');
  if (confidences.isNotEmpty) {
    final sorted = [...confidences]..sort();
    print('confidence: min ${sorted.first.toStringAsFixed(4)}  '
        'median ${sorted[sorted.length ~/ 2].toStringAsFixed(4)}  '
        'max ${sorted.last.toStringAsFixed(4)}');
    print('the threshold is ${CaptchaSolution.minConfidence}');
  }
}
