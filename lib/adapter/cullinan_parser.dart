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
import '../core/portal.dart';
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
  /// **One listing per (hall, option) pair.** The row is a (date, slot) pair.
  /// Its food dropdown lists the meals on offer and its hall dropdown lists
  /// the halls they are offered in, so a row with two dishes in two halls
  /// yields four listings.
  ///
  /// The cross product is deliberate. A claim POST names a hall *and* a dish
  /// (`drpSelf` + `drpFood`), so each combination is separately purchasable and
  /// separately lost. Collapsing them would hide the second hall from the
  /// ranker, and the user's "Engineering as a fallback" would silently never
  /// fire.
  ///
  /// The hall list is what the portal publishes for that row, never a
  /// hardcoded pair: the portal names halls per account, and serves different
  /// ones on different days.
  static List<Listing> parseBasket(String html, DateTime date) {
    final listings = <Listing>[];

    for (final row in tableRows(html, 'grdFoodBasketReservation')) {
      if (row.cells.length < 4) continue;

      final slot = mealSlotByPersianName[row.cell(1).trim()];
      if (slot == null) continue;

      final food = selectBySuffix(row.raw, 'drpFood');
      final self = selectBySuffix(row.raw, 'drpSelf');
      if (food == null || self == null) continue;

      final halls = <Hall>[
        for (final option in self.options)
          if (option.value != '-1')
            Hall(id: option.value, name: option.text),
      ];
      if (halls.isEmpty) continue;

      for (final option in food.options) {
        if (option.value == '-1') continue;
        final price = parseRial(option.text);
        if (price == null) continue;

        final menuOption = MenuOption(
          id: option.value,
          name: dishName(option.text),
          priceRial: price,
        );

        for (final hall in halls) {
          listings.add(Listing.composite(
            date: date,
            slot: slot,
            hall: hall,
            option: menuOption,
          ));
        }
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

  /// The buy page's date, as the portal's Jalali string.
  ///
  /// Read from `txtDate`, which is the page's own filter and always agrees
  /// with the rows it renders — verified live 2026-10-20.
  static String? buyPageDate(String html) {
    final match = RegExp(
      '<input[^>]*id="[^"]*txtDate"[^>]*value="([^"]*)"',
      dotAll: true,
    ).firstMatch(html);
    final value = match?.group(1)?.trim();
    return (value == null || value.isEmpty) ? null : value;
  }

  /// The complete form state of the buy page, with one listing selected.
  ///
  /// **The complete state, not one row.** The buy page is an ASP.NET grid, and
  /// an absent checkbox reads as *unchecked* on the server — so posting only
  /// the row being bought would silently release whatever else the account
  /// holds on that page. This mirrors what a browser sends, and matches the
  /// live capture of the one successful purchase
  /// (`captures/82_buy_post_body.txt`).
  ///
  /// [listingId] selects the row and the option; [hallId] overrides the hall,
  /// which is what makes the user's hall preference take effect.
  static Map<String, String> claimFormBody(
    String html, {
    required String listingId,
    required String hallId,
    String? date,
  }) {
    final body = <String, String>{
      '__VIEWSTATE': hiddenFieldValue(html, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': hiddenFieldValue(html, '__VIEWSTATEGENERATOR'),
      '__VIEWSTATEENCRYPTED': '',
      '__EVENTTARGET': '',
      '__EVENTARGUMENT': '',
    };
    if (date != null) body['ctl00\$cphMain\$txtDate'] = date;

    // Every row's current state, so nothing is released by omission. The row
    // carrying the target listing is written last, so its values win.
    for (final row in tableRows(html, 'grdFoodBasketReservation')) {
      final food = selectBySuffix(row.raw, 'drpFood');
      final self = selectBySuffix(row.raw, 'drpSelf');
      final count = selectBySuffix(row.raw, 'drpFoodCount');
      if (food == null || self == null) continue;

      final checkbox = inputBySuffix(row.raw, 'chkReserve');
      final isTarget = food.options.any((o) => o.value == listingId);

      // Preserve an existing held meal. An absent checkbox reads as unchecked,
      // so dropping it would give the meal back.
      if (checkbox != null && checkbox.checked) body[checkbox.name] = 'on';

      body[self.name] = self.selected?.value ?? '-1';
      body[food.name] = food.selected?.value ?? '-1';
      if (count != null) body[count.name] = count.selected?.value ?? '-1';

      if (!isTarget) continue;

      if (checkbox != null) body[checkbox.name] = 'on';
      body[self.name] = hallId;
      body[food.name] = listingId;
      // The row renders count 0 when it has no service, and a count of 0 buys
      // nothing — the listing's presence is what makes the row buyable.
      if (count != null) body[count.name] = '1';
    }

    body['ctl00\$cphMain\$btnSave'] = 'ذخیره';
    return body;
  }

  /// Whether the buy page shows [optionId] as **held**: checked and charged.
  ///
  /// This is the only reliable success signal. Verified live 2026-10-20 against
  /// the response to a real purchase: the bought option's row comes back
  /// `checked` with a non-zero amount, and the option is **still listed** in
  /// the dropdown. So "the option disappeared" is not a success test, and a
  /// client that used it would mis-report a completed, irreversible purchase as
  /// a failure — and keep hunting into a second one.
  ///
  /// Returns null when no row offers the option at all.
  static BasketHoldStatus? heldOnBuyPage(String html, String optionId) {
    for (final row in tableRows(html, 'grdFoodBasketReservation')) {
      if (row.cells.length < 7) continue;

      final food = selectBySuffix(row.raw, 'drpFood');
      if (food == null) continue;
      if (!food.options.any((o) => o.value == optionId)) continue;

      final checkbox = inputBySuffix(row.raw, 'chkReserve');
      return BasketHoldStatus(
        checked: checkbox?.checked ?? false,
        amountRial: parseRial(row.cell(6)) ?? 0,
      );
    }
    return null;
  }

  /// The Persian meal names the ledger uses.
  static const Map<String, MealSlot> _ledgerSlots = {
    'صبحانه': MealSlot.breakfast,
    'ناهار': MealSlot.lunch,
    'شام': MealSlot.dinner,
  };

  /// Parses the transaction ledger.
  ///
  /// **The main grid is NOT enough.** `MyCullinan/MyTransaction.aspx` renders a
  /// single row in `grdContent` — the most recent transaction — and keeps the
  /// full history in `grdContent_grdDetail_N` sub-grids (verified: 13 rows
  /// before a purchase, 14 after). Reading only the main grid would make the
  /// account look like it had a single transaction ever.
  static List<Transaction> parseTransactions(
    String html, {
    AccountId accountId = '',
  }) {
    final out = <Transaction>[];

    // The detail sub-grids carry the history; the main grid carries the newest
    // row, which is also the first detail grid's row. Collect the details, and
    // fall back to the main grid if there are none.
    final detailIds = RegExp(r'id="(cphMain_grdContent_grdDetail_\d+)"')
        .allMatches(html)
        .map((m) => m.group(1)!)
        .toList();

    for (final id in detailIds) {
      final table = RegExp(
        '<table[^>]*id="${RegExp.escape(id)}"[^>]*>(.*?)</table>',
        dotAll: true,
      ).firstMatch(html);
      if (table == null) continue;
      out.addAll(_transactionRows(table.group(1)!, accountId));
    }

    if (out.isEmpty) {
      final main = RegExp('<table[^>]*id="[^"]*grdContent"[^>]*>(.*?)</table>',
              dotAll: true)
          .firstMatch(html);
      if (main != null) {
        out.addAll(_transactionRows(main.group(1)!, accountId));
      }
    }

    return out;
  }

  static List<Transaction> _transactionRows(
    String tableBody,
    AccountId accountId,
  ) {
    final out = <Transaction>[];

    for (final row in RegExp(r'<tr[^>]*>(.*?)</tr>', dotAll: true)
        .allMatches(tableBody)) {
      final cells = RegExp(r'<td[^>]*>(.*?)</td>', dotAll: true)
          .allMatches(row.group(1)!)
          .map((m) => stripTags(m.group(1)!))
          .toList();
      if (cells.length < 7) continue;
      if (cells[0].trim().isEmpty) continue;

      out.add(Transaction(
        accountId: accountId,
        type: cells[0].trim(),
        foodName: cells[1].trim(),
        slot: _ledgerSlots[cells[2].trim()],
        weekday: cells[3].trim(),
        date: cells[4].trim(),
        count: int.tryParse(cells[5].trim()) ?? 0,
        amountRial: parseRial(cells[6]) ?? 0,
      ));
    }

    return out;
  }

  /// True when the row's reserve checkbox is disabled, meaning the date is
  /// locked by the server.
  static bool _isDisabled(String rowHtml, String suffix) =>
      inputBySuffix(rowHtml, suffix)?.disabled ?? false;

  static bool _sameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static String _dateKey(DateTime date) =>
      '${date.year}-${date.month}-${date.day}';
}
