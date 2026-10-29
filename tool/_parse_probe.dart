// Read-only: what does the app's own parser make of the portal's page?
// ignore_for_file: avoid_print

library;

import 'dart:io';

import 'package:bahonar_nut/adapter/cullinan_parser.dart';

void main(List<String> args) {
  final html = File(args[0]).readAsStringSync();
  final reservations = CullinanParser.parseReservations(html);
  print('parsed ${reservations.length} reservations');
  for (final r in reservations) {
    print('  ${r.date.toIso8601String().substring(0, 10)} ${r.slot.name} '
        'price=${r.option.priceRial} dish=${r.option.name}');
  }
}
