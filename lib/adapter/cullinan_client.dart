/// The Cullinan portal adapter: the only code that knows this particular
/// website exists.
///
/// Everything above this file reasons in domain terms (listings, reservations,
/// meals) and everything below it moves bytes. When the university redesigns
/// their site, this file is what breaks — and it is the only thing that should.
///
/// ## What the portal's pages actually look like
///
/// `FoodBasketBuy.aspx` renders one row per (date, meal slot) for a single
/// date, chosen by the `txtDate` filter. Each row carries a `chkReserve`
/// checkbox, a hall dropdown, a **food dropdown holding the purchasable
/// options**, a count dropdown, a price, and a shared `btnSave`.
///
/// The important consequence: **the individual listings live in the food
/// dropdown, not in the grid rows.** A row for lunch carried two options
/// (`62726` and `62729`), each with its own menu item and price. A "listing" is
/// therefore `(date, slot, option id)` — which is why
/// [Listing.compositeListingId] exists.
///
/// `Reservation.aspx` renders three grids (breakfast, lunch, dinner) of seven
/// days each, with a per-grid `btnSaveBreakfast` / `btnSaveLunch` /
/// `btnSaveDinner`.
///
/// The portal is ASP.NET WebForms: every POST must carry `__VIEWSTATE` from the
/// page it came from, and `__EVENTVALIDATION` is absent, so option ids come
/// from the live dropdowns rather than from constants.
library;

import '../core/models.dart';
import '../core/portal.dart';
import '../core/persian.dart';
import '../core/session_manager.dart'
    show
        LoginRejectedException,
        PortalUnreachableException,
        ReservationLockedException;
import '../transport/html_parsing.dart';
import '../transport/http_transport.dart';
import 'cullinan_parser.dart';

/// Portal paths.
class _Paths {
  static const login = '/';
  static const reservation = '/Reservation/Reservation.aspx';
  static const basketBuy = '/FoodBasket/FoodBasketBuy.aspx';
  static const transactions = '/MyCullinan/MyTransaction.aspx';
  static const captcha = '/UserControls/Captcha.ashx';
  static const topUp = '/ePay/ePay_Payment.aspx';
}

/// The Cullinan implementation of [PortalClient].
class CullinanPortalClient implements PortalClient {
  CullinanPortalClient({
    required this.transport,
    DateTime Function()? now,
  }) : _now = now ?? (() => DateTime.now().toUtc());

  final PortalTransport transport;
  final DateTime Function() _now;

  /// The pending login state, keyed by account.
  ///
  /// The portal binds a CAPTCHA answer to the session at image-fetch time, so
  /// the viewstate captured with the challenge must be the one submitted with
  /// the answer. Keeping them together per account is what makes the login
  /// sequence atomic.
  final Map<AccountId, _PendingLogin> _pendingLogins = {};

  // ---------------------------------------------------------------- auth

  @override
  Future<LoginChallenge?> beginLogin(String username) async {
    final accountId = username;
    final response = await transport.get(accountId, _Paths.login);

    // The challenge must be fetched in the same session, immediately before the
    // POST: re-fetching the page in between rotates the expected answer.
    final captchaBytes = await transport.getBytes(accountId, _Paths.captcha);

    _pendingLogins[accountId] = _PendingLogin(
      viewState: hiddenFieldValue(response.body, '__VIEWSTATE'),
      viewStateGenerator: hiddenFieldValue(response.body, '__VIEWSTATEGENERATOR'),
    );

    return LoginChallenge(
      imageBytes: captchaBytes,
      kind: ChallengeKind.digits4,
    );
  }

  @override
  Future<Session> completeLogin({
    required String username,
    required String password,
    LoginChallengeResponse? challenge,
  }) async {
    final accountId = username;
    final pending = _pendingLogins.remove(accountId);

    final body = <String, String>{
      // The viewstate must accompany the answer: it is what ties the POST to
      // the page and session the challenge was issued against.
      '__VIEWSTATE': pending?.viewState ?? '',
      '__VIEWSTATEGENERATOR': pending?.viewStateGenerator ?? '',
      '__VIEWSTATEENCRYPTED': '',
      '__EVENTTARGET': '',
      '__EVENTARGUMENT': '',
      'txtUsername': username,
      'txtPassword': password,
      'btnLogin': 'ورود سمت سرور ',
    };
    if (challenge != null) body['txtCaptcha'] = challenge.answer;

    final response = await transport.post(accountId, _Paths.login, body: body);

    // A failed login re-renders the login page with an error label. A
    // successful login ends up on the reservation hub, because the transport
    // follows the portal's 302.
    final error = labelText(response.body, 'lblLoginError');
    if (response.looksLikeLoginPage || error != null) {
      throw LoginRejectedException(error ?? 'ورود ناموفق بود.');
    }

    final jar = transport.jars.jarFor(accountId);
    return Session(
      account: accountId,
      cookies: jar.cookies,
      establishedAt: _now(),
    );
  }

  @override
  Future<Session> refresh(Session session) async {
    // A session refresh is a cheap authenticated GET: if the portal still
    // recognises the cookies it serves the page, and if not it bounces to the
    // login form.
    final response = await transport.get(session.account, _Paths.reservation);
    if (response.looksLikeLoginPage) {
      throw const LoginRejectedException('نشست منقضی شده است.');
    }
    final jar = transport.jars.jarFor(session.account);
    return Session(
      account: session.account,
      cookies: jar.cookies,
      establishedAt: session.establishedAt,
    );
  }

  @override
  Future<void> logout(Session session) async {
    // The portal exposes logout as a postback to a `ctl00$logout` event target.
    final page = await transport.get(session.account, _Paths.reservation);
    await transport.post(session.account, _Paths.reservation, body: {
      '__VIEWSTATE': hiddenFieldValue(page.body, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': hiddenFieldValue(page.body, '__VIEWSTATEGENERATOR'),
      '__EVENTTARGET': 'ctl00\$logout',
      '__EVENTARGUMENT': '',
    });
    transport.jars.remove(session.account);
  }

  // ---------------------------------------------------------------- time

  @override
  Future<DateTime> fetchServerTime(Session session) async {
    // The `Date` header is authoritative and needs no page of its own.
    final response = await transport.get(session.account, _Paths.reservation);
    final serverDate = response.serverDateUtc;
    if (serverDate == null) {
      throw const PortalUnreachableException('سرور زمان را برنگرداند.');
    }
    return serverDate;
  }

  // ---------------------------------------------------------------- reads

  @override
  Future<Balance> fetchBalance(Session session) async {
    final page = await transport.get(session.account, _Paths.reservation);
    final text = labelText(page.body, 'lblCredit');
    if (text == null) {
      throw const PortalUnreachableException('موجودی خوانده نشد.');
    }
    final amount = parseRial(text);
    if (amount == null) {
      throw PortalUnreachableException('موجودی قابل تفسیر نبود: $text');
    }
    return Balance(amountRial: amount, fetchedAt: _now());
  }

  @override
  Future<List<MealOffering>> fetchOfferings(
    Session session,
    DateTime date,
  ) async {
    final page = await transport.get(session.account, _Paths.reservation);
    return _parseOfferings(page.body, date);
  }

  @override
  Future<List<Reservation>> fetchReservations(Session session) async {
    final page = await transport.get(session.account, _Paths.reservation);
    return _parseReservations(page.body);
  }

  @override
  Future<List<Transaction>> fetchTransactions(Session session) async {
    final page = await transport.get(session.account, _Paths.transactions);
    return CullinanParser.parseTransactions(page.body);
  }

  @override
  Future<BasketPage> fetchBasket(Session session, {String? cursor}) async {
    // The basket page is filtered by date. The cursor is the Jalali date, so a
    // caller can page through the days ahead of the cutoff.
    final date = cursor ?? _todayJalali();
    final page = await transport.get(
      session.account,
      _Paths.basketBuy,
      headers: {},
    );
    return BasketPage(listings: _parseBasket(page.body, date));
  }

  // ---------------------------------------------------------------- writes

  @override
  Future<ClaimResult> claim(Session session, ListingId listingId) async {
    // The claim posts the buy page's own form: the row's checkbox, hall, food
    // and count, plus `btnSave`. `listingId` is the composite
    // `date|slot|optionId`, so it is decomposed back into the parts the form
    // needs.
    final parts = _parseListingId(listingId);
    if (parts == null) {
      return const ClaimRejected('شناسه آگهی معتبر نیست.');
    }

    try {
      final page = await transport.get(session.account, _Paths.basketBuy);
      final outcome = await _submitBasketRow(session, page.body, parts);
      return outcome;
    } on TransportException catch (e) {
      // A transport failure is genuinely ambiguous: the request may have been
      // processed before the connection broke. The engine reconciles rather
      // than retrying, so reporting ambiguity here is the safe choice.
      return ClaimAmbiguous(e.message);
    }
  }

  @override
  Future<Reservation> reserve(Session session, MealOffering offering) async {
    final page = await transport.get(session.account, _Paths.reservation);
    final grid = _gridForSlot(offering.slot);
    final body = _reservationFormBody(page.body, offering, grid);
    final response = await transport.post(
      session.account,
      _Paths.reservation,
      body: body,
    );

    if (response.looksLikeLoginPage) {
      throw const LoginRejectedException('نشست منقضی شده است.');
    }

    // The server either re-renders the grid with the reservation held, or
    // reports a problem. Reading it back is the only honest confirmation.
    final reservations = _parseReservations(response.body);
    for (final reservation in reservations) {
      if (reservation.slot == offering.slot &&
          _sameDate(reservation.date, offering.date) &&
          reservation.hall.id == offering.hall.id) {
        return reservation;
      }
    }

    // Nothing held, and no error was reported.
    //
    // A **locked date is refused silently**: the row renders `disabled` and the
    // server ignores the post entirely — no error label, no alert box, no state
    // change. Verified live (2026-10-19): posting a reservation for 1405/07/28,
    // whose cutoff had passed three days earlier, produced an identical page
    // and no reservation. So the absence of a reservation after a save is NOT
    // proof of a transport problem, and a client that waited for an error
    // message would wait forever.
    //
    // Distinguish the two by re-reading the row: a locked row still renders
    // `disabled`, which is the server's own statement that the date is closed.
    if (_isLockedForSlot(response.body, offering)) {
      throw ReservationLockedException(
        'مهلت رزرو این تاریخ به پایان رسیده است.',
        date: offering.date,
        slot: offering.slot,
      );
    }

    throw const PortalUnreachableException('رزرو تأیید نشد.');
  }

  /// True when the portal still renders this date's row as locked.
  ///
  /// The lock is the server's own signal, and it survives a refused post.
  bool _isLockedForSlot(String html, MealOffering offering) {
    final gridId = switch (offering.slot) {
      MealSlot.breakfast => 'grdReservationBreakfast',
      MealSlot.lunch => 'grdReservationLunch',
      MealSlot.dinner => 'grdReservationDinner',
    };

    for (final row in tableRows(html, gridId)) {
      if (row.cells.length < 4) continue;
      final date = parseJalaliDate(row.cell(1));
      if (date == null || !_sameDate(date, offering.date)) continue;

      // The checkbox is the server's lock marker.
      final checkbox = inputBySuffix(row.raw, 'chkReserve');
      return checkbox?.disabled ?? false;
    }

    return false;
  }

  @override
  Future<void> cancel(Session session, MealId mealId) async {
    final page = await transport.get(session.account, _Paths.reservation);
    await transport.post(session.account, _Paths.reservation, body: {
      '__VIEWSTATE': hiddenFieldValue(page.body, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': hiddenFieldValue(page.body, '__VIEWSTATEGENERATOR'),
      '__EVENTTARGET': '',
      '__EVENTARGUMENT': '',
      'ctl00\$cphMain\$btnCancelHidden': mealId,
    });
  }

  @override
  Uri? topUpUrl(Session session) => transport.resolve(_Paths.topUp);

  // ------------------------------------------------------------- internals

  /// The Jalali date string for today, as the portal expects it.
  String _todayJalali() {
    final jalali = toJalali(_now());
    return '${jalali.year}/${jalali.month.toString().padLeft(2, '0')}/'
        '${jalali.day.toString().padLeft(2, '0')}';
  }

  /// Parses the three reservation grids into offerings.
  List<MealOffering> _parseOfferings(String html, DateTime targetDate) =>
      CullinanParser.parseOfferings(html, targetDate);

  /// Parses the three reservation grids into the reservations held.
  List<Reservation> _parseReservations(String html) =>
      CullinanParser.parseReservations(html);

  /// Parses the basket buy grid into listings.
  List<Listing> _parseBasket(String html, String jalaliDate) {
    final date = parseJalaliDate(jalaliDate);
    if (date == null) return const [];
    return CullinanParser.parseBasket(html, date);
  }

  /// Submits the buy page's form for one listing.
  Future<ClaimResult> _submitBasketRow(
    Session session,
    String html,
    _ListingParts parts,
  ) async {
    // Find the row that carries this option, and take its control names.
    String? checkName;
    String? hallName;
    String? foodName;
    String? countName;
    String? countValue;

    for (final row in tableRows(html, 'grdFoodBasketReservation')) {
      final food = selectBySuffix(row.raw, 'drpFood');
      if (food == null) continue;
      if (!food.options.any((o) => o.value == parts.optionId)) continue;

      final checkbox = inputBySuffix(row.raw, 'chkReserve');
      final self = selectBySuffix(row.raw, 'drpSelf');
      final count = selectBySuffix(row.raw, 'drpFoodCount');

      checkName = checkbox?.name;
      hallName = self?.name;
      foodName = food.name;
      countName = count?.name;
      countValue = count?.selected?.value ?? count?.options.firstOrNull?.value;
      break;
    }

    if (checkName == null || hallName == null || foodName == null) {
      return const ClaimRejected('این آگهی دیگر در دسترس نیست.');
    }

    final body = <String, String>{
      '__VIEWSTATE': hiddenFieldValue(html, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': hiddenFieldValue(html, '__VIEWSTATEGENERATOR'),
      '__EVENTTARGET': '',
      '__EVENTARGUMENT': '',
      checkName: 'on',
      hallName: parts.hallId,
      foodName: parts.optionId,
      'ctl00\$cphMain\$btnSave': 'ذخیره',
    };
    if (countName != null) {
      body[countName] = countValue ?? '1';
    }

    final response = await transport.post(
      session.account,
      _Paths.basketBuy,
      body: body,
    );

    if (response.looksLikeLoginPage) {
      return const ClaimRejected('نشست منقضی شده است.');
    }

    // The server reports a failure in the status column of the grid, and a
    // success by the row no longer offering the option.
    final error = _basketError(response.body);
    if (error != null) {
      return ClaimRejected(error);
    }

    final stillOffered = _parseBasket(response.body, _todayJalali())
        .any((l) => l.option.id == parts.optionId);
    if (stillOffered) {
      return const ClaimRejected('خرید انجام نشد.');
    }

    return ClaimSucceeded(Reservation(
      id: parts.optionId,
      date: parts.date,
      slot: parts.slot,
      hall: Hall(id: parts.hallId, name: ''),
      option: MenuOption(
        id: parts.optionId,
        name: '',
        priceRial: parts.priceRial,
      ),
      state: ReservationState.active,
    ));
  }

  /// The error text the basket page shows for a failed purchase, if any.
  String? _basketError(String html) {
    // The status column carries the outcome. A row that failed shows text in
    // its last cell.
    for (final row in tableRows(html, 'grdFoodBasketReservation')) {
      if (row.cells.length < 8) continue;
      final status = row.cell(7).trim();
      if (status.isEmpty) continue;
      if (status.contains('موجودی') ||
          status.contains('ناموفق') ||
          status.contains('خطا')) {
        return status;
      }
    }
    return null;
  }

  /// The reservation form body for reserving one offering.
  Map<String, String> _reservationFormBody(
    String html,
    MealOffering offering,
    String gridId,
  ) {
    final body = <String, String>{
      '__VIEWSTATE': hiddenFieldValue(html, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': hiddenFieldValue(html, '__VIEWSTATEGENERATOR'),
      '__EVENTTARGET': '',
      '__EVENTARGUMENT': '',
    };

    for (final row in tableRows(html, gridId)) {
      final date = parseJalaliDate(row.cell(1));
      if (date == null || !_sameDate(date, offering.date)) continue;

      final checkbox = inputBySuffix(row.raw, 'chkReserve');
      final self = selectBySuffix(row.raw, 'drpSelf');
      final food = selectBySuffix(row.raw, 'drpFood');
      final count = selectBySuffix(row.raw, 'drpFoodCount');
      if (checkbox == null ||
          self == null ||
          food == null ||
          count == null) {
        continue;
      }

      body[checkbox.name] = 'on';
      body[self.name] = offering.hall.id;
      body[food.name] = offering.option.id;
      body[count.name] = count.options.firstOrNull?.value ?? '1';
      break;
    }

    body[_gridSaveButton(offering.slot)] = 'ذخیره';
    return body;
  }

  static String _gridForSlot(MealSlot slot) => switch (slot) {
        MealSlot.breakfast => 'grdReservationBreakfast',
        MealSlot.lunch => 'grdReservationLunch',
        MealSlot.dinner => 'grdReservationDinner',
      };

  static String _gridSaveButton(MealSlot slot) => switch (slot) {
        MealSlot.breakfast => 'ctl00\$cphMain\$btnSaveBreakfast',
        MealSlot.lunch => 'ctl00\$cphMain\$btnSaveLunch',
        MealSlot.dinner => 'ctl00\$cphMain\$btnSaveDinner',
      };

  static bool _sameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

/// The parts of a composite listing id.
class _ListingParts {
  const _ListingParts({
    required this.date,
    required this.slot,
    required this.optionId,
    required this.hallId,
    required this.priceRial,
  });

  final DateTime date;
  final MealSlot slot;
  final String optionId;
  final String hallId;
  final int priceRial;
}

/// Parses a composite listing id back into its parts.
_ListingParts? _parseListingId(String id) {
  final parts = id.split('|');
  if (parts.length != 3) return null;

  final date = DateTime.tryParse(parts[0]);
  if (date == null) return null;

  final slot = MealSlot.values.where((s) => s.name == parts[1]).firstOrNull;
  if (slot == null) return null;

  return _ListingParts(
    date: DateTime.utc(date.year, date.month, date.day),
    slot: slot,
    optionId: parts[2],
    hallId: '',
    priceRial: 0,
  );
}

/// The state captured between fetching a challenge and answering it.
class _PendingLogin {
  const _PendingLogin({
    required this.viewState,
    required this.viewStateGenerator,
  });

  final String viewState;
  final String viewStateGenerator;
}
