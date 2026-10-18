/// Renders digests and nudge status into notification text.
///
/// Both functions here are **pure**: no clock, no I/O, no Flutter. The message
/// the user reads is the deliverable of this whole subsystem, so it is generated
/// by a pure function and asserted directly in tests rather than verified by
/// eyeballing a rendered notification.
///
/// Every string is Persian, matching the app's Persian-first RTL design.
library;

import 'models.dart';
import 'next_week.dart';
import 'persian.dart';
import 'reminder.dart';
import 'time.dart';

/// Maximum gaps listed in a nudge body before truncating.
///
/// A notification body is not a scrollable report; the detail screen shows all.
const int maxGapsListed = 5;

/// Renders a daily reminder digest.
///
/// Section rules:
///   * A meal section lists only accounts holding that reservation.
///   * A meal with no reservations anywhere omits its whole section.
///   * If every covered slot is empty, the body says so explicitly rather than
///     rendering an empty-looking notification that reads as a bug.
///   * Unchecked accounts are always named at the end. A briefing that looks
///     complete but is missing a line is the one unacceptable outcome.
NotificationText composeNotification(ReminderDigest digest) {
  final coveredSlots = _slotsFor(digest.slot);
  final title = _titleFor(digest);

  final sections = <String>[];
  for (final slot in coveredSlots) {
    final section = _sectionFor(digest, slot);
    if (section != null) sections.add(section);
  }

  final buffer = StringBuffer();
  if (sections.isEmpty) {
    buffer.write('امروز هیچ وعده رزروشده‌ای ندارید.');
  } else {
    buffer.write(sections.join('\n\n'));
  }

  final failureLine = _failureLine(digest.failures);
  if (failureLine != null) {
    buffer.write('\n\n$failureLine');
  }

  return NotificationText(
    title: title,
    body: buffer.toString(),
    summary: _summaryFor(digest, coveredSlots),
  );
}

/// Renders the next-week reservation nudge.
///
/// Callers must only invoke this when a gap exists; a complete week is meant to
/// be silent, and that decision belongs to the caller, not here.
NotificationText composeNudgeNotification(NextWeekStatus status) {
  final buffer = StringBuffer();

  buffer.write('هنوز برای هفته آینده رزرو نکرده‌اید.\n');

  final weekLabel =
      '${toJalali(status.weekStart).dayMonth} تا ${toJalali(status.weekEnd).dayMonth}';
  buffer.write('هفته آینده: $weekLabel\n');

  final deadlineLine = _deadlineLine(status);
  if (deadlineLine != null) buffer.write('$deadlineLine\n');

  buffer.write('\n');

  final shown = status.gaps.take(maxGapsListed).toList();
  for (final gap in shown) {
    buffer.write('• ${_gapLine(gap)}\n');
  }
  if (status.gaps.length > maxGapsListed) {
    final remaining = status.gaps.length - maxGapsListed;
    buffer.write('و ${toPersianDigits(remaining)} وعده دیگر\n');
  }

  final failureLine = _failureLine(status.failures);
  if (failureLine != null) {
    buffer.write('\n$failureLine');
  }

  return NotificationText(
    title: '📅 یادآوری رزرو هفته آینده',
    body: buffer.toString().trimRight(),
    summary: '${toPersianDigits(status.gaps.length)} وعده رزرو نشده است',
  );
}

/// Renders the message posted when a reminder could not run at all.
NotificationText composeFailureNotification({
  required ReminderSlot slot,
  required String reason,
}) =>
    NotificationText(
      title: '⚠️ یادآوری انجام نشد',
      body: 'یادآوری امروز اجرا نشد.\n$reason',
    );

// --- internals ---

Set<MealSlot> _slotsFor(ReminderSlot slot) => switch (slot) {
      ReminderSlot.lunch => const {MealSlot.lunch},
      ReminderSlot.evening => const {MealSlot.dinner, MealSlot.breakfast},
    };

String _titleFor(ReminderDigest digest) => switch (digest.slot) {
      ReminderSlot.lunch => '🍽 یادآوری ناهار امروز',
      ReminderSlot.evening => '🌙 یادآوری شام امروز',
    };

String? _sectionFor(ReminderDigest digest, MealSlot slot) {
  final entries = digest.itemsForSlot(slot);
  if (entries.isEmpty) return null;

  final header = _sectionHeader(digest, slot);
  final lines = <String>[];
  for (final (account, item) in entries) {
    lines.add('• ${account.displayName} — ${item.dishName} — ${item.hallName}');
  }
  return '$header\n${lines.join('\n')}';
}

String _sectionHeader(ReminderDigest digest, MealSlot slot) {
  final date = digest.accounts
      .expand((a) => a.items)
      .where((i) => i.slot == slot)
      .map((i) => i.date)
      .fold<DateTime?>(
        null,
        (latest, d) => latest == null || d.isAfter(latest) ? d : latest,
      );

  final dateLabel = date == null ? '' : formatPersianDate(date);

  return switch (slot) {
    MealSlot.breakfast =>
      '🍳 صبحانه فردا ($dateLabel) — همراه شام امروز تحویل می‌گیرید:',
    MealSlot.lunch => '🍽 ناهار ($dateLabel):',
    MealSlot.dinner => '🌙 شام ($dateLabel):',
  };
}

String? _failureLine(List<ReminderFailure> failures) {
  if (failures.isEmpty) return null;
  final names = failures.map((f) => f.displayName).join('، ');
  return '⚠️ بررسی نشد: $names';
}

String? _summaryFor(ReminderDigest digest, Set<MealSlot> slots) {
  var count = 0;
  for (final slot in slots) {
    count += digest.itemsForSlot(slot).length;
  }
  if (count == 0) return 'رزروی ثبت نشده';
  return '${toPersianDigits(count)} وعده رزرو شده';
}

String? _deadlineLine(NextWeekStatus status) {
  // The deadline is the portal's own cutoff (20:00 local), so it is rendered
  // from ClockTime.cutoff rather than hardcoded a second time.
  final time = formatClockTimePersian(ClockTime.cutoff.hour, ClockTime.cutoff.minute);
  return 'مهلت اولین وعده: ${persianWeekdays[status.deadline.weekday]} ساعت $time';
}

String _gapLine(BookingGap gap) {
  final meal = switch (gap.slot) {
    MealSlot.breakfast => 'صبحانه',
    MealSlot.lunch => 'ناهار',
    MealSlot.dinner => 'شام',
  };
  final date = toJalali(gap.date);
  final dayLabel = '${toPersianDigits(date.day)} ${date.monthName}';
  return '$dayLabel — $meal: رزرو نشده';
}