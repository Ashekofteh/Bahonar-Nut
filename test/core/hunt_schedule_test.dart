/// When a hunt actually runs — the collection date, and the wake instant.
///
/// The defect these pin is F83: a hunt's window was a bare time of day, so a
/// hunt for tomorrow's dinner, started in the morning, found its window open
/// *today*, hunted today's market — which it could never buy from — burned its
/// request budget against it, and ended a day early.
///
/// The breakfast case is the sharpest: breakfast is collected with the
/// previous evening's dinner, so a hunt for Friday's breakfast has to be in
/// the market on *Thursday*.
library;

import 'package:bahonar_nut/core/hunt_config.dart';
import 'package:bahonar_nut/core/hunt_schedule.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/snipe.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:test/test.dart';

/// A civil date, in the portal's frame.
DateTime day(int year, int month, int dayOfMonth) =>
    DateTime.utc(year, month, dayOfMonth);

void main() {
  group('the collection date', () {
    test('a lunch is collected on its own date', () {
      expect(
        HuntSchedules.collectionDate(
          targetDate: day(2026, 10, 22),
          slot: MealSlot.lunch,
        ),
        day(2026, 10, 22),
      );
    });

    test('a dinner is collected on its own date', () {
      expect(
        HuntSchedules.collectionDate(
          targetDate: day(2026, 10, 22),
          slot: MealSlot.dinner,
        ),
        day(2026, 10, 22),
      );
    });

    test('a breakfast is collected the evening before', () {
      // 2026-10-22 is a Thursday; a breakfast for Thursday is collected with
      // Wednesday's dinner, so the collection day is the Wednesday.
      expect(
        HuntSchedules.collectionDate(
          targetDate: day(2026, 10, 22),
          slot: MealSlot.breakfast,
        ),
        day(2026, 10, 21),
      );
    });

    test('a breakfast whose collection evening has no dinner does not exist',
        () {
      // 2026-10-23 is a Friday. Its collection evening is Thursday, which
      // serves no dinner — so Friday has no breakfast to collect.
      expect(
        HuntSchedules.collectionDate(
          targetDate: day(2026, 10, 23),
          slot: MealSlot.breakfast,
        ),
        isNull,
      );
    });

    test('a breakfast collected on a Saturday evening exists', () {
      // 2026-10-25 is a Sunday, collected with Saturday's dinner, and
      // Saturday does serve dinner.
      expect(
        HuntSchedules.collectionDate(
          targetDate: day(2026, 10, 25),
          slot: MealSlot.breakfast,
        ),
        day(2026, 10, 24),
      );
    });

    test('a target with no date has no collection date', () {
      expect(
        HuntSchedules.collectionDate(targetDate: null, slot: MealSlot.dinner),
        isNull,
      );
    });
  });

  group('the wake instant', () {
    test('a dinner for tomorrow wakes tomorrow, not today', () {
      // Now is Wednesday 2026-10-21 at 09:00 portal-local.
      final now = DateTime.utc(2026, 10, 21, 5, 30);

      final result = HuntSchedules.scheduleFor(
        targetDate: day(2026, 10, 22),
        slot: MealSlot.dinner,
        windowStart: const ClockTime(16, 30),
        windowEnd: const ClockTime(20, 30),
        nowUtc: now,
      );

      expect(result.isScheduled, isTrue);
      final schedule = result.schedule!;
      expect(schedule.collectionDate, day(2026, 10, 22));

      // 16:30 portal-local == 13:00 UTC (the portal is UTC+3:30).
      expect(schedule.wakeAtUtc, DateTime.utc(2026, 10, 22, 13, 0));
      expect(schedule.windowEndUtc, DateTime.utc(2026, 10, 22, 17, 0));
    });

    test('a breakfast for tomorrow wakes tonight', () {
      // The breakfast of 2026-10-22 is collected with the dinner of
      // 2026-10-21, so the window opens on the 21st — the same evening the
      // student set the hunt up.
      final now = DateTime.utc(2026, 10, 21, 5, 30);

      final result = HuntSchedules.scheduleFor(
        targetDate: day(2026, 10, 22),
        slot: MealSlot.breakfast,
        windowStart: const ClockTime(16, 30),
        windowEnd: const ClockTime(20, 30),
        nowUtc: now,
      );

      expect(result.isScheduled, isTrue);
      expect(result.schedule!.collectionDate, day(2026, 10, 21));
      expect(result.schedule!.wakeAtUtc, DateTime.utc(2026, 10, 21, 13, 0));
    });

    test('a window on a later day is not treated as having passed', () {
      // A dinner for the 22nd, set up at 21:00 on the 21st: the 22nd's
      // window has not closed — it has not even opened.
      final now = DateTime.utc(2026, 10, 21, 17, 30);

      final result = HuntSchedules.scheduleFor(
        targetDate: day(2026, 10, 22),
        slot: MealSlot.dinner,
        windowStart: const ClockTime(16, 30),
        windowEnd: const ClockTime(20, 30),
        nowUtc: now,
      );

      expect(result.isScheduled, isTrue);
      expect(result.schedule!.wakeAtUtc, DateTime.utc(2026, 10, 22, 13, 0));
    });

    test('a window that has already closed is not scheduled', () {
      // A dinner for today (the 21st), configured at 21:00 portal-local —
      // after the 20:30 window closed. The meal it is for is released in that
      // window, so there is nothing left to hunt for.
      final now = DateTime.utc(2026, 10, 21, 17, 30);

      final result = HuntSchedules.scheduleFor(
        targetDate: day(2026, 10, 21),
        slot: MealSlot.dinner,
        windowStart: const ClockTime(16, 30),
        windowEnd: const ClockTime(20, 30),
        nowUtc: now,
      );

      expect(result.status, HuntScheduleStatus.windowPassed);
      expect(result.isScheduled, isFalse);
    });

    test('a window that never opens is not scheduled', () {
      final result = HuntSchedules.scheduleFor(
        targetDate: day(2026, 10, 22),
        slot: MealSlot.dinner,
        windowStart: const ClockTime(20, 30),
        windowEnd: const ClockTime(16, 30),
        nowUtc: DateTime.utc(2026, 10, 21, 5, 30),
      );

      expect(result.status, HuntScheduleStatus.windowInvalid);
    });

    test('a breakfast that does not exist is not scheduled', () {
      // A Friday breakfast is collected with Thursday's dinner, and Thursday
      // serves no dinner — so there is no such breakfast to hunt for.
      final result = HuntSchedules.scheduleFor(
        targetDate: day(2026, 10, 23),
        slot: MealSlot.breakfast,
        windowStart: const ClockTime(16, 30),
        windowEnd: const ClockTime(20, 30),
        nowUtc: DateTime.utc(2026, 10, 21, 5, 30),
      );

      expect(result.status, HuntScheduleStatus.mealNotServed);
    });

    test('a hunt with no target date is not scheduled', () {
      final result = HuntSchedules.scheduleFor(
        targetDate: null,
        slot: MealSlot.dinner,
        windowStart: const ClockTime(16, 30),
        windowEnd: const ClockTime(20, 30),
        nowUtc: DateTime.utc(2026, 10, 21, 5, 30),
      );

      expect(result.status, HuntScheduleStatus.noTargetDate);
    });
  });

  group('the rule carries the collection date', () {
    SnipeRule ruleFor(MealSlot slot, DateTime? target) => HuntConfig(
          targetSlot: slot,
          targetDate: target,
        ).toRule(id: 'r1', account: 'a1');

    test('a dinner rule opens on its own date', () {
      final rule = ruleFor(MealSlot.dinner, day(2026, 10, 22));
      expect(rule.windowDate, day(2026, 10, 22));
    });

    test('a breakfast rule opens the evening before', () {
      final rule = ruleFor(MealSlot.breakfast, day(2026, 10, 22));
      expect(rule.windowDate, day(2026, 10, 21));
    });

    test('a breakfast that does not exist carries no window date', () {
      final rule = ruleFor(MealSlot.breakfast, day(2026, 10, 23));
      expect(rule.windowDate, isNull);
    });
  });

  group('the window is checked against the date as well as the time', () {
    final rule = SnipeRule(
      id: 'r1',
      account: 'a1',
      preferences: const {},
      windowStart: const ClockTime(16, 30),
      windowEnd: const ClockTime(20, 30),
      windowDate: day(2026, 10, 22),
    );

    test('the window is closed on another day, even at the right time', () {
      expect(
        rule.isOpenAt(const ClockTime(17, 0), day(2026, 10, 21)),
        isFalse,
        reason: 'a hunt for the 22nd must not open the 21st\'s window',
      );
    });

    test('the window is open on its own day', () {
      expect(rule.isOpenAt(const ClockTime(17, 0), day(2026, 10, 22)), isTrue);
    });

    test('the time of day is still enforced on its own day', () {
      expect(rule.isOpenAt(const ClockTime(9, 0), day(2026, 10, 22)), isFalse);
    });

    test('a rule with no date keeps the time-of-day behaviour', () {
      final plain = SnipeRule(
        id: 'r2',
        account: 'a1',
        preferences: const {},
        windowStart: const ClockTime(16, 30),
        windowEnd: const ClockTime(20, 30),
      );

      expect(plain.isOpenAt(const ClockTime(17, 0), day(2026, 10, 21)), isTrue);
    });

    test('an unknown date falls back to the time of day', () {
      expect(rule.isOpenAt(const ClockTime(17, 0), null), isTrue,
          reason: 'a date nobody can name is not a reason to refuse the window');
    });
  });
}
