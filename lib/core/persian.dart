/// Persian (Jalali) calendar and digit formatting.
///
/// Pure Dart, no dependencies. Kept separate from the composer so the calendar
/// conversion can be tested directly against known portal dates — the portal is
/// the authority on what "26 مهر 1405" means, and the conversion is verified
/// against it (`persian_test.dart`).
library;

/// Persian month names, indexed 1..12.
const List<String> persianMonths = [
  '',
  'فروردین',
  'اردیبهشت',
  'خرداد',
  'تیر',
  'مرداد',
  'شهریور',
  'مهر',
  'آبان',
  'آذر',
  'دی',
  'بهمن',
  'اسفند',
];

/// Persian weekday names, indexed by `DateTime.weekday` (Mon=1 .. Sun=7).
const List<String> persianWeekdays = [
  '',
  'دوشنبه',
  'سه‌شنبه',
  'چهارشنبه',
  'پنج‌شنبه',
  'جمعه',
  'شنبه',
  'یکشنبه',
];

/// A civil date in the Jalali calendar.
class JalaliDate {
  const JalaliDate(this.year, this.month, this.day);

  final int year;
  final int month;
  final int day;

  String get monthName => persianMonths[month];

  /// e.g. `26 مهر`
  String get dayMonthPersian => '${toPersianDigits(day)} $monthName';

  /// e.g. `۲۶ مهر`
  String get dayMonth => '${toPersianDigits(day)} $monthName';

  /// e.g. `1405/07/26`
  String get numericPersian => '${toPersianDigits(year)}/'
      '${toPersianDigits(month).padLeft(2, '۰')}/'
      '${toPersianDigits(day).padLeft(2, '۰')}';

  @override
  String toString() => '$year/$month/$day';

  @override
  bool operator ==(Object other) =>
      other is JalaliDate &&
      other.year == year &&
      other.month == month &&
      other.day == day;

  @override
  int get hashCode => Object.hash(year, month, day);
}

/// Converts a Gregorian civil date to Jalali.
///
/// Standard algorithm (Borkowski / the widely used `jalaali-js` form), accurate
/// across the range this app cares about. The Gregorian input's time component
/// and timezone are ignored; only the civil date matters.
JalaliDate toJalali(DateTime gregorian) {
  const gDaysInMonth = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334];

  final gy = gregorian.year;
  final gm = gregorian.month;
  final gd = gregorian.day;

  final gy2 = gm > 2 ? gy + 1 : gy;

  var days = 355666 +
      (365 * gy) +
      ((gy2 + 3) ~/ 4) -
      ((gy2 + 99) ~/ 100) +
      ((gy2 + 399) ~/ 400) +
      gd +
      gDaysInMonth[gm - 1];

  var jy = -1595 + (33 * (days ~/ 12053));
  days %= 12053;
  jy += 4 * (days ~/ 1461);
  days %= 1461;

  if (days > 365) {
    jy += (days - 1) ~/ 365;
    days = (days - 1) % 365;
  }

  final int jm;
  final int jd;
  if (days < 186) {
    jm = 1 + (days ~/ 31);
    jd = 1 + (days % 31);
  } else {
    jm = 7 + ((days - 186) ~/ 30);
    jd = 1 + ((days - 186) % 30);
  }

  return JalaliDate(jy, jm, jd);
}

/// Converts a Jalali civil date to Gregorian.
///
/// The inverse of [toJalali], and needed because the portal's grids label rows
/// in Jalali (`شنبه 1405/08/02`) while the app reasons in Gregorian civil
/// dates. The conversion is exact: 1405/07/26 is 2026-10-18.
///
/// Implemented as a bounded search over the *verified* [toJalali] rather than
/// as a second hand-written algorithm. Two independent date algorithms is two
/// chances to be wrong; and when the first attempt at the inverse was written
/// it was wrong — it returned July instead of October — while [toJalali] had
/// already been checked against the portal's own dates. Deriving the inverse
/// from the verified forward function makes the pair correct by construction,
/// and the search is over a window of a few hundred days, so it is cheap.
DateTime fromJalali(JalaliDate jalali) {
  // The Jalali year runs March-to-March, so a Jalali year maps to the Gregorian
  // year that is 621 greater (1405 -> 2026). Searching the whole of that
  // Gregorian year plus the next is ample.
  final approximateYear = jalali.year + 621;
  final start = DateTime.utc(approximateYear, 1, 1);
  final end = DateTime.utc(approximateYear + 2, 1, 1);

  var candidate = start;
  while (candidate.isBefore(end)) {
    if (toJalali(candidate) == jalali) return candidate;
    candidate = candidate.add(const Duration(days: 1));
  }

  throw ArgumentError(
    'no Gregorian date maps to Jalali ${jalali.year}/${jalali.month}/${jalali.day}',
  );
}

/// Parses a Jalali date in the portal's `yyyy/MM/dd` form.
///
/// Returns null for anything that is not a Jalali date, so a caller never
/// mistakes an unparsed label for the epoch.
DateTime? parseJalaliDate(String text) {
  final match = RegExp(r'(\d{1,4})\s*[/\\-]\s*(\d{1,2})\s*[/\\-]\s*(\d{1,2})')
      .firstMatch(text);
  if (match == null) return null;

  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;

  return fromJalali(JalaliDate(year, month, day));
}

/// Formats a Gregorian date as e.g. `یکشنبه ۲۶ مهر`.
String formatPersianDate(DateTime date) {
  final jalali = toJalali(date);
  return '${persianWeekdays[date.weekday]} ${jalali.dayMonth}';
}

/// Formats a Gregorian date as e.g. `یکشنبه ۲۶ مهر ۱۴۰۵`.
String formatPersianDateWithYear(DateTime date) {
  final jalali = toJalali(date);
  return '${persianWeekdays[date.weekday]} ${jalali.dayMonth} '
      '${toPersianDigits(jalali.year)}';
}

/// Converts ASCII digits in [input] to Persian digits, leaving other characters
/// untouched.
///
/// Used for user-facing text only. Identifiers, prices sent over the wire and
/// anything compared programmatically keep ASCII digits — mixing the two is a
/// classic and painful bug class.
String toPersianDigits(Object input) {
  const western = '0123456789';
  const persian = '۰۱۲۳۴۵۶۷۸۹';
  final text = input.toString();
  final buffer = StringBuffer();
  for (final rune in text.runes) {
    final char = String.fromCharCode(rune);
    final index = western.indexOf(char);
    buffer.write(index >= 0 ? persian[index] : char);
  }
  return buffer.toString();
}

/// Formats a Rial amount for display, e.g. `۳۵۰٬۰۰۰ ریال`.
String formatRialPersian(int amountRial) {
  final digits = amountRial.abs().toString();
  final grouped = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) grouped.write('٬');
    grouped.write(digits[i]);
  }
  final sign = amountRial < 0 ? '−' : '';
  return '$sign${toPersianDigits(grouped.toString())} ریال';
}

/// A clock time rendered in Persian, e.g. `۲۰:۰۰`.
String formatClockTimePersian(int hour, int minute) {
  final h = toPersianDigits(hour.toString().padLeft(2, '0'));
  final m = toPersianDigits(minute.toString().padLeft(2, '0'));
  return '$h:$m';
}