import 'package:bahonar_nut/core/persian.dart';

void main() {
  for (final s in ['1405/07/25', '1405/07/28', '1405/07/29', '1405/08/02', '1405/08/03']) {
    final d = parseJalaliDate(s);
    print('$s -> ${d?.toIso8601String().substring(0, 10)}');
  }
}
