/// When a hunt actually runs: the date its window belongs to, and the instant
/// the hunt should wake up.
///
/// ## Why the window needs a date, not just a time of day
///
/// A hunt's window is a *time of day* — "from 16:30 to 20:30". That is enough
/// to decide **how hard** to poll, but not enough to decide **when to start**.
/// A hunt set up on Wednesday morning for *Friday's* dinner has a window that
/// opens on Friday, not on Wednesday — but a time-of-day window read on
/// Wednesday says "16:30 is later today, so the window is still to come", and
/// the hunt would burn its request budget against a market it can never buy
/// from.
///
/// So the window is resolved against a **collection date**, and the resolution
/// has one wrinkle the portal's own calendar imposes:
///
/// **Breakfast is collected with the previous evening's dinner.** A hunt for
/// Friday's breakfast has to be in the market on *Thursday* evening, because
/// that is when the meal is released and taken. The offset is therefore
/// derived from the serving calendar rather than assumed, and the
/// [ServiceCalendar] already encodes it: Thursday has no dinner, so Friday has
/// no breakfast, and Saturday has no breakfast because Friday has no dinner.
///
/// ## Why the wake instant is the window's *start*
///
/// The hunt is worth running from the moment the window opens — every minute
/// before the first listing appears is a minute of not winning it. So the
/// wake instant is the window's start on the collection date, in the portal's
/// own timezone: a portal-local wall-clock time is a UTC instant only once the
/// portal's offset is subtracted, and getting that wrong by 3½ hours would
/// start the hunt before the market opens.
library;

import 'models.dart';
import 'service_calendar.dart';
import 'time.dart';

/// The schedule of one hunt: when it wakes up, and when it gives up.
class HuntSchedule {
  const HuntSchedule({
    required this.collectionDate,
    required this.wakeAtUtc,
    required this.windowEndUtc,
  });

  /// The civil date, in the portal's frame, on which the hunt's window falls.
  ///
  /// This is the **collection date**: the day the meal is actually taken. For
  /// a breakfast it is the day *before* the target date, because the
  /// breakfast is collected with the previous evening's dinner.
  final DateTime collectionDate;

  /// The instant the hunt should wake up, in UTC.
  final DateTime wakeAtUtc;

  /// The instant the hunt's window closes, in UTC.
  ///
  /// The window's end on the collection date. The hunt gives up here even if
  /// it has not bought anything, because after this the market is closed for
  /// that meal.
  final DateTime windowEndUtc;

  @override
  String toString() => 'HuntSchedule(collection $collectionDate, '
      'wake $wakeAtUtc, end $windowEndUtc)';
}

/// Derives a hunt's schedule from its target and its window.
abstract final class HuntSchedules {
  /// The collection date for a target date and meal slot.
  ///
  /// ## The rule
  ///
  ///  * **breakfast** is collected with the *previous* evening's dinner, so it
  ///    is collected on the day before the target date;
  ///  * **lunch** and **dinner** are collected on the target date itself.
  ///
  /// ## Why the calendar is consulted
  ///
  /// The rule is not a constant offset, because the *serving* calendar decides
  /// it: Thursday has no dinner, so Friday has no breakfast to collect. A
  /// breakfast whose collection day is a day the halls serve no dinner does not
  /// exist, and the hunt has nothing to buy — so the schedule is null and the
  /// screen says so, rather than the hunt waiting for a window that can never
  /// open.
  ///
  /// A target date that is null has no schedule: the target is resolved at
  /// setup time, and a hunt without a date cannot be scheduled.
  static DateTime? collectionDate({
    required DateTime? targetDate,
    required MealSlot slot,
    ServiceCalendar calendar = const ServiceCalendar(),
  }) {
    final date = targetDate;
    if (date == null) return null;

    final day = DateTime.utc(date.year, date.month, date.day);

    if (slot != MealSlot.breakfast) return day;

    // Breakfast is collected the evening before, with that day's dinner.
    final evening = day.subtract(const Duration(days: 1));

    // If the halls serve no dinner that evening, there is no breakfast to
    // collect — so the breakfast does not exist and there is nothing to hunt.
    if (!calendar.isServedOn(evening, MealSlot.dinner)) return null;

    return evening;
  }

  /// The schedule for a hunt.
  ///
  /// The result carries a **status**, because "the hunt cannot run" has more
  /// than one reason and the screen has to say which:
  ///
  ///  * [HuntScheduleStatus.noTargetDate] — the hunt has no date, so there is
  ///    nothing to aim at;
  ///  * [HuntScheduleStatus.mealNotServed] — the meal does not exist on that
  ///    date (a breakfast whose collection evening serves no dinner);
  ///  * [HuntScheduleStatus.windowPassed] — the window has already closed, so
  ///    the hunt has missed its moment and there is nothing left to wait for;
  ///  * [HuntScheduleStatus.windowInvalid] — the window ends before it starts,
  ///    so it can never open.
  ///
  /// The last two are not the same, and neither is the first: a hunt that
  /// missed its window needs a new target, while a hunt that was never
  /// scheduled needs one too — but the student has to be told which, because
  /// "your hunt will not run" with no reason is a dead end.
  ///
  /// ## The unsynced clock
  ///
  /// [clockIsSynced] says whether [nowUtc] is the **portal's** time. When it
  /// is not, the caller is passing the device's time as a stand-in, and the
  /// device's timezone may be anything at all — so the question "has the
  /// window already closed?" cannot be answered from it.
  ///
  /// So an unsynced clock never produces [HuntScheduleStatus.windowPassed].
  /// The hunt is scheduled instead, and the alarm fires: if the window has in
  /// fact passed, the hunt's own date-aware window check refuses it, and the
  /// refusal is visible. Cancelling the alarm instead would make the hunt
  /// silently never run — the exact failure F83 is about.
  static HuntScheduleResult scheduleFor({
    required DateTime? targetDate,
    required MealSlot slot,
    required ClockTime windowStart,
    required ClockTime windowEnd,
    required DateTime nowUtc,
    bool clockIsSynced = true,
    ServiceCalendar calendar = const ServiceCalendar(),
  }) {
    // A window that never opens is not a schedule.
    if (windowEnd <= windowStart) {
      return const HuntScheduleResult(
        status: HuntScheduleStatus.windowInvalid,
      );
    }

    if (targetDate == null) {
      return const HuntScheduleResult(
        status: HuntScheduleStatus.noTargetDate,
      );
    }

    final collection = collectionDate(
      targetDate: targetDate,
      slot: slot,
      calendar: calendar,
    );
    if (collection == null) {
      return const HuntScheduleResult(
        status: HuntScheduleStatus.mealNotServed,
      );
    }

    // The window's instants on the collection date, in the portal's timezone.
    final wakeAt = _portalInstant(collection, windowStart);
    final windowEnds = _portalInstant(collection, windowEnd);

    // The window has closed, or the collection day is already past.
    //
    // This is not "schedule it for tomorrow": the window belongs to the
    // collection date, and the meal it is for is released in that window. A
    // hunt that wakes tomorrow would be polling a market that no longer
    // carries the meal — spending the request budget to find nothing.
    final today = DateTime.utc(
      nowUtc.year,
      nowUtc.month,
      nowUtc.day,
    );
    if (clockIsSynced &&
        (collection.isBefore(today) || windowEnds.isBefore(nowUtc))) {
      return const HuntScheduleResult(
        status: HuntScheduleStatus.windowPassed,
      );
    }

    return HuntScheduleResult(
      status: HuntScheduleStatus.scheduled,
      schedule: HuntSchedule(
        collectionDate: collection,
        wakeAtUtc: wakeAt,
        windowEndUtc: windowEnds,
      ),
    );
  }

  /// A portal-local wall-clock time on [day], as a UTC instant.
  ///
  /// The portal's offset is subtracted, because a wall-clock time in the
  /// portal's timezone is a *later* instant than the same digits read as UTC.
  static DateTime _portalInstant(DateTime day, ClockTime time) => DateTime.utc(
        day.year,
        day.month,
        day.day,
        time.hour,
        time.minute,
      ).subtract(ServerClock.portalUtcOffset);
}

/// Why a hunt is or is not scheduled.
enum HuntScheduleStatus {
  /// The hunt has a schedule, and the wake instant is known.
  scheduled,

  /// The hunt is switched off, so it must not run at all.
  ///
  /// Not a fault: this is the student's decision. It is a status rather than
  /// an absence, because the screen has to say *why* the hunt will not start.
  disabled,

  /// The hunt has no target date, so there is nothing to aim at.
  noTargetDate,

  /// The meal is not served on the target date, so there is nothing to buy.
  mealNotServed,

  /// The window has already closed. The hunt has missed its moment.
  windowPassed,

  /// The window ends before it starts, so it can never open.
  windowInvalid,
}

/// The outcome of scheduling a hunt.
class HuntScheduleResult {
  const HuntScheduleResult({required this.status, this.schedule});

  /// Why the hunt is or is not scheduled.
  final HuntScheduleStatus status;

  /// The schedule, when there is one.
  final HuntSchedule? schedule;

  /// Whether the hunt will start by itself.
  bool get isScheduled =>
      status == HuntScheduleStatus.scheduled && schedule != null;

  @override
  String toString() => 'HuntScheduleResult($status, $schedule)';
}
