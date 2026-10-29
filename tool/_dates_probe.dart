/// READ-ONLY: the dates the hunt screen would offer, computed by the app's
/// own code, so the device test targets a date the app actually serves.
library;

// ignore_for_file: avoid_print

import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/service_calendar.dart';
import 'package:bahonar_nut/core/time.dart';

void main() {
  const calendar = ServiceCalendar();
  // The portal's now, as the app sees it.
  final nowUtc = DateTime.utc(2026, 10, 22, 12, 40);
  final clock = _Fixed(nowUtc);
  print('portal now: ${clock.portalNow}');
  final first = clock.firstReservableDate();
  print('first reservable: $first');
  final dates = List.generate(
    7,
    (i) => DateTime.utc(first.year, first.month, first.day + i),
  );
  print('offered range: ${dates.first} .. ${dates.last}');
  for (final slot in MealSlot.values) {
    final servable = calendar.servableDates(dates, slot);
    print('  ${slot.name}: ${servable.map((d) => d.toIso8601String().substring(0,10)).join(", ")}');
  }
}

class _Fixed implements ServerClock {
  _Fixed(this._now);
  final DateTime _now;
  @override
  bool get isSynced => true;
  @override
  Duration get staleness => Duration.zero;
  @override
  DateTime get nowUtc => _now;
  @override
  DateTime get portalNow => _now.add(ServerClock.portalUtcOffset);
  @override
  DateTime get portalTodayUtc => DateTime.utc(portalNow.year, portalNow.month, portalNow.day);
  @override
  DateTime reservationLockTimeUtc(DateTime targetDate) =>
      DateTime.utc(targetDate.year, targetDate.month, targetDate.day - 2, 20).subtract(ServerClock.portalUtcOffset);
  @override
  bool isLocked(DateTime targetDate) => !nowUtc.isBefore(reservationLockTimeUtc(targetDate));
  @override
  bool isReservable(DateTime targetDate) => !isLocked(targetDate);
  @override
  DateTime firstReservableDate() {
    final today = portalTodayUtc;
    final candidate = DateTime.utc(today.year, today.month, today.day + 2);
    return isReservable(candidate) ? candidate : DateTime.utc(candidate.year, candidate.month, candidate.day + 1);
  }
  @override
  int minutesUntilLock(DateTime targetDate) =>
      reservationLockTimeUtc(targetDate).difference(nowUtc).inMinutes;
}
