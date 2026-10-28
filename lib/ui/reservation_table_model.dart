/// The model behind the reservations table.
///
/// ## Why the table has its own model
///
/// The table answers one question: **what is the state of every meal the
/// student can have, for every day they can still act on?** That is not the
/// same question as "what does the mirror hold" (the reservations screen's
/// question), and it is not the same as "what does the portal serve" (the
/// hunt screen's question).
///
/// So the rows are **built**, not read. A row is a (date, slot) pair with a
/// status derived from three sources:
///
///   * the **menu** — which meals the portal serves, and at what price;
///   * the **mirror** — which of those the student already holds;
///   * the **clock** — which are already past their cutoff.
///
/// ## Why a row can exist without a menu
///
/// A day the portal does not serve still needs to be visible if the student
/// **holds** a meal on it — a basket purchase never appears in the weekly
/// grid (F16), so a menu-only table would hide a meal the student paid for.
/// So a row exists when the portal serves the meal **or** the student holds
/// it.
///
/// ## Why a row does not name a dish
///
/// A menu offers **several** dishes, and the student picks one when they
/// book. So a bookable row says how many options there are and what the
/// cheapest costs — and the dish is chosen in the booking sheet.
///
/// A **held** row names its dish, because that one is decided.
library;

import '../core/local_meal_store.dart';
import '../core/meal_invariant.dart';
import '../core/models.dart';
import '../core/persian.dart';
import '../core/time.dart';

/// What the student can do with a meal.
enum MealRowStatus {
  /// The student holds this meal, reserved for the week.
  held,

  /// The student holds this meal, bought from the Food Basket.
  ///
  /// A basket purchase is **irreversible** (F16) — there is no cancel. The
  /// row says so, because offering a cancel here would be a lie.
  bought,

  /// The meal is served and can still be reserved.
  bookable,

  /// The meal is served, but its cutoff has passed.
  ///
  /// The portal refuses a locked row **silently** (F: session 12), so the app
  /// has to say so before the student tries.
  locked,

  /// The student holds this meal, but its date has passed its cutoff.
  ///
  /// The meal is theirs and it is shown — they paid for it — but it can no
  /// longer be given back: the portal renders a locked row `disabled`, so the
  /// cancel post is discarded (F14). Offering a cancel button here would be
  /// offering one that silently does nothing (F63).
  heldLocked,
}

/// One row of the table: a (date, slot) pair and its state.
class MealRow {
  const MealRow({
    required this.date,
    required this.slot,
    required this.status,
    this.dishName,
    this.hallName,
    this.priceRial,
    this.optionCount = 0,
  });

  final DateTime date;
  final MealSlot slot;
  final MealRowStatus status;

  /// The dish of a **held** meal.
  ///
  /// Null for a bookable meal: several dishes are on offer and the student
  /// picks one when they book.
  final String? dishName;

  /// The hall a held meal is in.
  final String? hallName;

  /// The price in Rial.
  ///
  /// For a held meal, what was paid. For a bookable one, the **cheapest**
  /// option's price — the number a student looks at first.
  final int? priceRial;

  /// How many dishes the portal offers for a bookable meal.
  final int optionCount;

  /// Whether the student can cancel this meal.
  ///
  /// A basket purchase cannot be given back (F16), and a weekly reservation
  /// can only be cancelled while its date is still editable (F14).
  bool get cancellable => status == MealRowStatus.held;

  /// The status, in words.
  String get statusLabel => switch (status) {
        MealRowStatus.held => 'رزرو شده',
        MealRowStatus.heldLocked => 'رزرو شده - مهلت گذشته',
        MealRowStatus.bought => 'خریداری شده',
        MealRowStatus.bookable => 'قابل رزرو',
        MealRowStatus.locked => 'مهلت گذشته',
      };
}

/// Builds the rows of the table.
///
/// The rows come back in **date order, then meal order** — the order the
/// student experiences them in, so the table reads as a schedule rather than
/// as a set.
List<MealRow> buildMealRows({
  required List<MealMenu> menus,
  required List<StoredMeal> held,
  required ServerClock? clock,
}) {
  // The mirror's meals, keyed by (date, slot).
  final heldByKey = <String, StoredMeal>{};
  for (final meal in held) {
    heldByKey[_key(meal.date, meal.slot)] = meal;
  }

  // The menu entry for each (date, slot) the portal serves.
  final menuByKey = <String, MealMenu>{};
  for (final menu in menus) {
    menuByKey[_key(menu.date, menu.slot)] = menu;
  }

  // Every (date, slot) pair the table has a row for: the portal serves it,
  // or the student holds it.
  final dates = <String, DateTime>{};
  final slots = <String, MealSlot>{};
  for (final key in {...menuByKey.keys, ...heldByKey.keys}) {
    dates[key] = heldByKey[key]?.date ?? menuByKey[key]!.date;
    slots[key] = heldByKey[key]?.slot ?? menuByKey[key]!.slot;
  }

  final rows = <MealRow>[];
  for (final key in dates.keys) {
    final heldMeal = heldByKey[key];
    final menu = menuByKey[key];

    if (heldMeal != null) {
      // A held meal whose date has passed its cutoff can no longer be given
      // back: the portal renders a locked row `disabled` and discards the
      // cancel post (F14). The meal is still shown — the student holds it —
      // but it must not offer a cancel that would silently do nothing (F63).
      final locked = clock != null &&
          clock.isSynced &&
          !clock.isReservable(dates[key]!);

      rows.add(MealRow(
        date: dates[key]!,
        slot: slots[key]!,
        status: heldMeal.source == MealSource.basketPurchase
            ? MealRowStatus.bought
            : (locked ? MealRowStatus.heldLocked : MealRowStatus.held),
        dishName: heldMeal.dishName,
        hallName: heldMeal.hallName,
        priceRial: heldMeal.priceRial,
        optionCount: menu?.dishes.length ?? 0,
      ));
      continue;
    }

    // The portal does not serve this meal, and the student does not hold it.
    // There is nothing to show.
    if (menu == null) continue;

    // The cutoff. The portal refuses a locked row silently, so the app has to
    // say so first.
    final locked = clock != null &&
        clock.isSynced &&
        !clock.isReservable(dates[key]!);

    final cheapest = _cheapest(menu);

    rows.add(MealRow(
      date: dates[key]!,
      slot: slots[key]!,
      status: locked ? MealRowStatus.locked : MealRowStatus.bookable,
      priceRial: cheapest?.priceRial,
      optionCount: menu.dishes.length,
    ));
  }

  rows.sort((a, b) {
    final byDate = a.date.compareTo(b.date);
    if (byDate != 0) return byDate;
    return a.slot.index.compareTo(b.slot.index);
  });

  return rows;
}

/// The cheapest dish on the menu, which is the one the price cell carries.
MenuOption? _cheapest(MealMenu menu) {
  if (menu.dishes.isEmpty) return null;
  return menu.dishes.reduce(
    (a, b) => a.priceRial <= b.priceRial ? a : b,
  );
}

/// The key of a (date, slot) pair.
String _key(DateTime date, MealSlot slot) =>
    '${date.year}-${date.month}-${date.day}|${slot.name}';

/// The Persian name of a date, for the table's day headers.
String formatRowDate(DateTime date) => formatPersianDateWithYear(date);

/// The Saturday that begins the Iranian university dining week containing [date].
///
/// In the Iranian academic calendar, the dining week runs Saturday (شنبه) through
/// Friday (جمعه). Hours, minutes, and seconds are normalized to 00:00:00 UTC.
DateTime weekStartSaturday(DateTime date) {
  final utc = DateTime.utc(date.year, date.month, date.day);
  final daysSinceSaturday = (utc.weekday % 7); // Sat: 6 % 7 = 6, Sun: 7 % 7 = 0, Mon: 1, ..., Fri: 5
  final diff = (utc.weekday == DateTime.saturday) ? 0 : (daysSinceSaturday + 1);
  return utc.subtract(Duration(days: diff));
}

/// The Friday that ends the Iranian dining week starting at [saturday].
DateTime weekEndFriday(DateTime saturday) =>
    DateTime.utc(saturday.year, saturday.month, saturday.day + 6);

/// Filters rows down to those falling strictly within the week `[saturday, saturday + 6 days]`.
List<MealRow> filterRowsForWeek(List<MealRow> rows, DateTime saturday) {
  final start = DateTime.utc(saturday.year, saturday.month, saturday.day);
  final end = DateTime.utc(saturday.year, saturday.month, saturday.day + 6);
  return rows.where((row) {
    final d = DateTime.utc(row.date.year, row.date.month, row.date.day);
    return !d.isBefore(start) && !d.isAfter(end);
  }).toList();
}

/// Persian title for a relative week offset from current week (0 = current).
String formatWeekTitle(int weekOffset) {
  if (weekOffset == 0) return 'هفته جاری';
  if (weekOffset == 1) return 'هفته بعد';
  if (weekOffset == -1) return 'هفته قبل';
  if (weekOffset > 1) return '${toPersianDigits(weekOffset)} هفته بعد';
  return '${toPersianDigits(weekOffset.abs())} هفته قبل';
}

/// Formats the Jalali date range for the week starting on [saturday],
/// e.g. `۲۵ مهر الی ۱ آبان ۱۴۰۵`.
String formatWeekRange(DateTime saturday) {
  final friday = weekEndFriday(saturday);
  final jSat = toJalali(saturday);
  final jFri = toJalali(friday);

  if (jSat.year == jFri.year) {
    if (jSat.month == jFri.month) {
      return '${toPersianDigits(jSat.day)} الی ${toPersianDigits(jFri.day)} ${jSat.monthName} ${toPersianDigits(jSat.year)}';
    }
    return '${toPersianDigits(jSat.day)} ${jSat.monthName} الی ${toPersianDigits(jFri.day)} ${jFri.monthName} ${toPersianDigits(jSat.year)}';
  }
  return '${toPersianDigits(jSat.day)} ${jSat.monthName} ${toPersianDigits(jSat.year)} الی ${toPersianDigits(jFri.day)} ${jFri.monthName} ${toPersianDigits(jFri.year)}';
}

