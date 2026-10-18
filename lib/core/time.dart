/// Time handling for the Food Basket app.
///
/// The portal's servers define the reservation cutoff, so every cutoff decision
/// must be made against *server* time, never the device clock. Android device
/// clocks drift and users change timezones by hand; computing "20:00 two days
/// prior" locally on a skewed clock produces either false refusals (locking a
/// meal the student could still book) or early snipes (a burst of rejected
/// requests that looks exactly like an attack).
library;

/// A time of day with no date and no timezone.
///
/// Deliberately not Flutter's `TimeOfDay`: this library must stay pure Dart so
/// the domain remains testable on the VM (see README / spec §3.1).
class ClockTime implements Comparable<ClockTime> {
  const ClockTime(int hour, int minute)
      : assert(hour >= 0 && hour < 24, 'hour must be 0..23'),
        assert(minute >= 0 && minute < 60, 'minute must be 0..59'),
        minutesSinceMidnight = hour * 60 + minute;

  const ClockTime.fromMinutes(int minutes)
      : assert(minutes >= 0 && minutes < 1440, 'minutes must be 0..1439'),
        minutesSinceMidnight = minutes;

  final int minutesSinceMidnight;

  int get hour => minutesSinceMidnight ~/ 60;
  int get minute => minutesSinceMidnight % 60;

  /// The portal's reservation cutoff: 20:00 local.
  static const ClockTime cutoff = ClockTime(20, 0);

  @override
  int compareTo(ClockTime other) =>
      minutesSinceMidnight.compareTo(other.minutesSinceMidnight);

  bool operator <(ClockTime other) => compareTo(other) < 0;
  bool operator <=(ClockTime other) => compareTo(other) <= 0;
  bool operator >(ClockTime other) => compareTo(other) > 0;
  bool operator >=(ClockTime other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) =>
      other is ClockTime && other.minutesSinceMidnight == minutesSinceMidnight;

  @override
  int get hashCode => minutesSinceMidnight.hashCode;

  @override
  String toString() =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
}

/// Server clock. All cutoff logic derives from here.
///
/// Implementations obtain "now" from the portal (HTTP `Date` headers, corrected
/// for round-trip latency). A device-clock fallback is deliberately absent: if
/// the clock is not synced, callers must refuse to run auto-reserve rather than
/// guess.
abstract class ServerClock {
  /// Server's current instant, as UTC.
  DateTime get nowUtc;

  /// True once at least one sync has succeeded.
  bool get isSynced;

  /// How old the last successful sync is. Callers decide staleness policy.
  Duration get staleness;

  /// Days between the target meal date and its reservation deadline.
  ///
  /// Regulation 2091: reservations close at 20:00 on the day that is *two*
  /// calendar days before the meal date.
  static const int cutoffDaysBefore = 2;

  /// The portal's timezone offset. Iran abolished daylight saving in 2022, so
  /// UTC+3:30 applies year-round. Held as a constant to keep the arithmetic
  /// explicit and easy to revisit if DST is ever reinstated.
  static const Duration portalUtcOffset = Duration(hours: 3, minutes: 30);
}

/// A [`ServerClock`] backed by an explicit instant plus a sync timestamp.
///
/// Tests drive this directly; the live adapter feeds it from response headers.
class FixedServerClock implements ServerClock {
  FixedServerClock({required DateTime serverNowUtc, required this.syncedAt})
      : nowUtc = serverNowUtc.toUtc(),
        _syncAge = DateTime.now().toUtc().difference(syncedAt);

  /// Convenience for tests: a clock that believes it was synced just now.
  factory FixedServerClock.now(DateTime serverNowUtc) =>
      FixedServerClock(serverNowUtc: serverNowUtc, syncedAt: DateTime.now().toUtc());

  @override
  final DateTime nowUtc;

  final DateTime syncedAt;
  final Duration _syncAge;

  @override
  bool get isSynced => true;

  @override
  Duration get staleness => _syncAge;
}

/// Cutoff arithmetic. Pure functions over a [ServerClock], so tests can pin the
/// boundary exactly.
extension ReservationCutoff on ServerClock {
  /// `nowUtc` expressed as the portal's local wall clock.
  DateTime get portalNow =>
      nowUtc.add(ServerClock.portalUtcOffset);

  /// The date-only "today" as the portal sees it.
  ///
  /// Built with `DateTime.utc` deliberately: this is a *civil date* in the
  /// portal's frame, and using `DateTime(...)` (local) would re-introduce the
  /// device timezone we are trying to escape.
  DateTime get portalTodayUtc => DateTime.utc(
        portalNow.year,
        portalNow.month,
        portalNow.day,
      );

  /// The instant reservations lock for [targetDate].
  ///
  /// [targetDate] is a civil date (its time component is ignored). Returns a UTC
  /// instant corresponding to 20:00 portal-local, two days before the target.
  DateTime reservationLockTimeUtc(DateTime targetDate) {
    // 20:00 portal-local == 20:00 - 3:30 == 16:30 UTC on the same civil day.
    final lockDayUtc = DateTime.utc(
      targetDate.year,
      targetDate.month,
      targetDate.day - ServerClock.cutoffDaysBefore,
    );
    return DateTime.utc(
      lockDayUtc.year,
      lockDayUtc.month,
      lockDayUtc.day,
      ClockTime.cutoff.hour,
      0,
    ).subtract(ServerClock.portalUtcOffset);
  }

  /// True when reservations for [targetDate] are closed.
  bool isLocked(DateTime targetDate) =>
      !nowUtc.isBefore(reservationLockTimeUtc(targetDate));

  /// Still reservable?
  bool isReservable(DateTime targetDate) => !isLocked(targetDate);

  /// The first civil date beyond the cutoff wall — the earliest meal the student
  /// could still reserve today.
  ///
  /// If now is before today's 20:00 cutoff, the day after tomorrow is still open;
  /// once the cutoff passes, it rolls forward one more day.
  DateTime firstReservableDate() {
    final today = portalTodayUtc;
    final candidate = DateTime.utc(today.year, today.month, today.day + ServerClock.cutoffDaysBefore);
    return isReservable(candidate)
        ? candidate
        : DateTime.utc(candidate.year, candidate.month, candidate.day + 1);
  }

  /// Minutes until [targetDate] locks. Negative once locked.
  int minutesUntilLock(DateTime targetDate) =>
      reservationLockTimeUtc(targetDate).difference(nowUtc).inMinutes;
}