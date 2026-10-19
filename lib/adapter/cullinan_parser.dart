/// Parsing of the Cullinan portal's HTML into domain objects.
///
/// Split out from the client so it can be tested directly against captured
/// pages, with no transport and no network. The parsers are pure functions of
/// HTML text, which is what makes them verifiable: every assertion in
/// `cullinan_parser_test.dart` is a claim about real portal markup.
///
/// ## The page shapes this understands
///
/// `FoodBasketBuy.aspx` — one row per (date, meal slot), filtered by date.
/// The purchasable meals live in the row's **food dropdown**, one `<option>`
/// per listing, each with its own menu id and price. A row for lunch was seen
/// carrying two options, so a row is a slot and an option is a listing.
///
/// `Reservation.aspx` — three grids (breakfast, lunch, dinner) of seven days.
/// A held meal is the row whose `chkReserve` checkbox is `checked`; a locked
/// date is the row whose checkbox is `disabled`.
///
/// The portal is ASP.NET WebForms, so control names carry a `ctl00$cphMain$...`
/// prefix and row indices (`$ctl02`, `$ctl03`, ...). Names are matched by
/// suffix, because those indices shift whenever the portal changes a grid.
library;

import '../core/models.dart';
import '../core/persian.dart';
import '../transport/html_parsing.dart';

/// The Persian meal names the portal renders.
const Map<String, MealSlot> mealSlotByPersianName = {
  'صبحانه': MealSlot.breakfast,
  'ناهار': MealSlot.lunch,
  'شام': MealSlot.dinner,
};

/// Parses the portal's pages.
abstract final class CullinanParser {
  /// The reservation grid for a meal slot.
  static String gridIdFor(MealSlot slot) => switch (slot) {
        MealSlot.breakfast => 'grdReservationBreakfast',
        MealSlot.lunch => 'grdReservationLunch',
        MealSlot.dinner => 'grdReservationDinner',
      };

  /// The save button for a meal slot's grid.
  static String saveButtonFor(MealSlot slot) => switch (slot) {
        MealSlot.breakfast => 'ctl00\$cphMain\$btnSaveBreakfast',
        MealSlot.lunch => 'ctl00\$cphMain\$btnSaveLunch',
        MealSlot.dinner => 'ctl00\$cphMain\$btnSaveDinner',
      };

  /// The meal slots a reservation page carries, in grid order.
  static const List<MealSlot> reservationSlots = [
    MealSlot.breakfast,
    MealSlot.lunch,
    MealSlot.dinner,
  ];

  /// Parses the reservation grids into the meals available on [date].
  ///
  /// A row with no service renders `-` in the hall and food dropdowns and
  /// contributes nothing. A locked date still lists its options — the lock is
  /// expressed by the row's checkbox being `disabled` — so [MealOffering
  /// .reservable] reports it rather than hiding the option.
  static List<MealOffering> parseOfferings(String html, DateTime date) {
    final offerings = <MealOffering>[];

    for (final slot in reservationSlots) {
      for (final row in tableRows(html, gridIdFor(slot))) {
        if (row.cells.length < 4) continue;

        final rowDate = parseJalaliDate(row.cell(1));
        if (rowDate == null || !_sameDate(rowDate, date)) continue;

        final food = selectBySuffix(row.raw, 'drpFood');
        final self = selectBySuffix(row.raw, 'drpSelf');
        if (food == null || self == null) continue;

        final hallValue = self.selected?.value ?? '-1';
        if (hallValue == '-1') continue;

        final reservable = !_isDisabled(row.raw, 'chkReserve');

        for (final option in food.options) {
          if (option.value == '-1') continue;
          final price = parseRial(option.text);
          if (price == null) continue;

          offerings.add(MealOffering(
            date: rowDate,
            slot: slot,
            hall: Hall(id: hallValue, name: self.selected?.text ?? ''),
            option: MenuOption(
              id: option.value,
              name: dishName(option.text),
              priceRial: price,
            ),
            reservable: reservable,
          ));
        }
      }
    }

    return offerings;
  }

  /// Parses the reservation grids into the meals the student holds.
  ///
  /// A meal is held when its row's `chkReserve` checkbox is `checked`.
  static List<Reservation> parseReservations(String html) {
    final reservations = <Reservation>[];

    for (final slot in reservationSlots) {
      for (final row in tableRows(html, gridIdFor(slot))) {
        if (row.cells.length < 4) continue;

        final checkbox = inputBySuffix(row.raw, 'chkReserve');
        if (checkbox == null || !checkbox.checked) continue;

        final date = parseJalaliDate(row.cell(1));
        if (date == null) continue;

        final food = selectBySuffix(row.raw, 'drpFood');
        final self = selectBySuffix(row.raw, 'drpSelf');
        if (food == null || self == null) continue;

        final selected = food.selected;
        if (selected == null || selected.value == '-1') continue;

        final price = parseRial(selected.text) ?? 0;

        reservations.add(Reservation(
          id: 'row-${slot.name}-${_dateKey(date)}',
          date: date,
          slot: slot,
          hall: Hall(
            id: self.selected?.value ?? '-1',
            name: self.selected?.text ?? '',
          ),
          option: MenuOption(
            id: selected.value,
            name: dishName(selected.text),
            priceRial: price,
          ),
          state: ReservationState.active,
        ));
      }
    }

    return reservations;
  }

  /// Parses the basket buy grid into listings.
  ///
  /// **One listing per option in a row's food dropdown.** The row is a
  /// (date, slot) pair; the options within it are the purchasable meals. A row
  /// offering two options yields two listings.
  static List<Listing> parseBasket(String html, DateTime date) {
    final listings = <Listing>[];

    for (final row in tableRows(html, 'grdFoodBasketReservation')) {
      if (row.cells.length < 4) continue;

      final slot = mealSlotByPersianName[row.cell(1).trim()];
      if (slot == null) continue;

      final food = selectBySuffix(row.raw, 'drpFood');
      final self = selectBySuffix(row.raw, 'drpSelf');
      if (food == null || self == null) continue;

      final hallValue = self.selected?.value ?? '-1';
      if (hallValue == '-1') continue;

      for (final option in food.options) {
        if (option.value == '-1') continue;
        final price = parseRial(option.text);
        if (price == null) continue;

        listings.add(Listing.composite(
          date: date,
          slot: slot,
          hall: Hall(id: hallValue, name: self.selected?.text ?? ''),
          option: MenuOption(
            id: option.value,
            name: dishName(option.text),
            priceRial: price,
          ),
        ));
      }
    }

    return listings;
  }

  /// The name of a menu option, without its trailing price.
  ///
  /// The portal renders `زرشک پلو با مرغ,سس مرغ, ماست 500000 ریال`; the dish is
  /// everything before the price, and the price is parsed separately.
  static String dishName(String optionText) => optionText
      .replaceAll(RegExp(r'\s*\d[\d,٬]*\s*ریال\s*$'), '')
      .trim();

  /// True when the row's reserve checkbox is disabled, meaning the date is
  /// locked by the server.
  static bool _isDisabled(String rowHtml, String suffix) =>
      inputBySuffix(rowHtml, suffix)?.disabled ?? false;

  static bool _sameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static String _dateKey(DateTime date) =>
      '${date.year}-${date.month}-${date.day}';
}
