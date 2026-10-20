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

/// The weekly menu's "next week" postback target.
///
/// The weekly menu is one page per week, and this is how the portal moves to
/// the next one. It is a navigation, not a write.
const _eventTargetNextWeek = r'ctl00$cphMain$imgbtnNextWeek';

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
    _applySession(session);
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

  /// Puts [session]'s cookies into the transport's jar.
  ///
  /// The jar is filled by the responses the portal sends, so a session that
  /// was restored from storage — never a response — would go out
  /// unauthenticated. The portal would answer with the login page, and the
  /// read would be reported as an expired session rather than as a session
  /// that was never applied.
  void _applySession(Session session) {
    transport.restoreSession(session.account, session.cookies);
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
    _applySession(session);
    // The `Date` header is authoritative and needs no page of its own.
    final response = await transport.get(session.account, _Paths.reservation);
    final serverDate = response.serverDateUtc;
    if (serverDate == null) {
      throw const PortalUnreachableException('سرور زمان را برنگرداند.');
    }
    return serverDate;
  }

  // ---------------------------------------------------------------- reads

  /// Throws when a read came back as the login form rather than the page.
  ///
  /// The portal answers an expired session by serving the login page, which is
  /// a perfectly valid response — and which every parser downstream would
  /// misread as "the page had no rows". So the bounce is detected here and
  /// reported as [LoginRejectedException], which tells the caller to log in
  /// again rather than to conclude the account holds nothing.
  static void _rejectIfBounced(TransportResponse response) {
    if (response.looksLikeLoginPage) {
      throw const LoginRejectedException('نشست منقضی شده است.');
    }
  }

  @override
  Future<Balance> fetchBalance(Session session) async {
    _applySession(session);
    final page = await transport.get(session.account, _Paths.reservation);
    _rejectIfBounced(page);
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
    _applySession(session);
    final page = await transport.get(session.account, _Paths.reservation);
    _rejectIfBounced(page);
    return _parseOfferings(page.body, date);
  }

  @override
  Future<List<MealMenu>> fetchMenu(
    Session session,
    DateTime date,
  ) async {
    _applySession(session);
    final html = await _readMenuFor(session, date);
    return CullinanParser.parseMenu(html, date);
  }

  /// The weekly menu page that carries [date].
  ///
  /// ## Why the second page
  ///
  /// The weekly menu is **one page per week**. `Reservation.aspx` carries the
  /// current week; the next week is a separate page, reached by posting
  /// `ctl00$cphMain$imgbtnNextWeek`. The hunt's targetable range is seven
  /// days long, so it routinely crosses that boundary — and a read that only
  /// ever fetched the current week's page would find no menu for a target
  /// date in next week, and report it as "no food is served that day".
  ///
  /// So the page is fetched, and the target date is looked for in it. If it
  /// is not there, next week's page is fetched and looked in.
  ///
  /// The postback is a **navigation**, not a write: it carries no save button
  /// and changes nothing on the account.
  Future<String> _readMenuFor(Session session, DateTime date) async {
    final current = await transport.get(session.account, _Paths.reservation);
    _rejectIfBounced(current);

    if (_menuCovers(current.body, date)) return current.body;

    final next = await transport.post(
      session.account,
      _Paths.reservation,
      body: {
        '__VIEWSTATE': hiddenFieldValue(current.body, '__VIEWSTATE'),
        '__VIEWSTATEGENERATOR':
            hiddenFieldValue(current.body, '__VIEWSTATEGENERATOR'),
        '__EVENTTARGET': _eventTargetNextWeek,
        '__EVENTARGUMENT': '',
      },
    );
    _rejectIfBounced(next);

    return next.body;
  }

  /// Whether the menu page carries a row for [date].
  ///
  /// The date is compared by its **civil** form, because the grids label
  /// their rows in Jalali and a Jalali label is a date, not an instant.
  static bool _menuCovers(String html, DateTime date) {
    for (final menu in CullinanParser.parseMenu(html, date)) {
      if (menu.date.year == date.year &&
          menu.date.month == date.month &&
          menu.date.day == date.day) {
        return true;
      }
    }
    return false;
  }

  @override
  Future<List<Reservation>> fetchReservations(Session session) async {
    _applySession(session);
    final page = await transport.get(session.account, _Paths.reservation);
    _rejectIfBounced(page);
    return _parseReservations(page.body);
  }

  @override
  Future<List<Transaction>> fetchTransactions(Session session) async {
    _applySession(session);
    final page = await transport.get(session.account, _Paths.transactions);
    _rejectIfBounced(page);
    return CullinanParser.parseTransactions(
      page.body,
      accountId: session.account,
    );
  }

  @override
  Future<BasketPage> fetchBasket(Session session, {String? cursor}) async {
    _applySession(session);
    // The basket page is filtered by date, and the cursor is the Jalali date
    // the caller wants. Verified live 2026-10-20: the page's own `txtDate`
    // field agrees with the rows it renders, so a GET alone returns the page's
    // default date — reading it for any other date requires the filter
    // postback.
    final wanted = cursor ?? _todayJalali();
    final first = await transport.get(session.account, _Paths.basketBuy);
    _rejectIfBounced(first);

    if (CullinanParser.buyPageDate(first.body) == wanted) {
      return BasketPage(listings: _parseBasket(first.body, wanted));
    }

    final filtered = await transport.post(
      session.account,
      _Paths.basketBuy,
      body: {
        '__VIEWSTATE': hiddenFieldValue(first.body, '__VIEWSTATE'),
        '__VIEWSTATEGENERATOR':
            hiddenFieldValue(first.body, '__VIEWSTATEGENERATOR'),
        '__EVENTTARGET': '',
        '__EVENTARGUMENT': '',
        'ctl00\$cphMain\$txtDate': wanted,
        'ctl00\$cphMain\$imgbtnGoToDate.x': '1',
        'ctl00\$cphMain\$imgbtnGoToDate.y': '1',
      },
    );

    if (filtered.looksLikeLoginPage) {
      throw const LoginRejectedException('نشست منقضی شده است.');
    }

    return BasketPage(listings: _parseBasket(filtered.body, wanted));
  }

  // ---------------------------------------------------------------- writes

  @override
  Future<ClaimResult> claim(Session session, ListingId listingId) async {
    _applySession(session);
    // `listingId` is the composite `date|slot|hall|option`, so it is
    // decomposed back into the parts the claim POST needs. The hall is part of
    // the identity: a purchase names a hall as well as a dish.
    final parts = _parseListingId(listingId);
    if (parts == null) {
      return const ClaimRejected('شناسه آگهی معتبر نیست.');
    }

    try {
      // The page must be read for the listing's own date, not the default one.
      final html = await _readBuyPage(session, parts.date);
      // Awaited inside the try so that a transport failure *during the POST* is
      // reported as ambiguous rather than escaping as an exception: the server
      // may have completed the purchase before the connection broke, and the
      // engine's whole safety story rests on that being a distinct outcome.
      return await _submitBasketRow(session, html, parts);
    } on TransportException catch (e) {
      // A transport failure is genuinely ambiguous: the request may have been
      // processed before the connection broke. The engine reconciles rather
      // than retrying, so reporting ambiguity here is the safe choice.
      return ClaimAmbiguous(e.message);
    }
  }

  @override
  Future<Reservation> reserve(Session session, MealOffering offering) async {
    _applySession(session);
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
  Future<BasketHoldStatus?> holdingsOnBuyPage(
    Session session, {
    required DateTime date,
    required String optionId,
  }) async {
    final html = await _readBuyPage(session, date);
    return CullinanParser.heldOnBuyPage(html, optionId);
  }

  @override
  Future<void> cancel(Session session, MealId mealId) async {
    _applySession(session);
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
  String _todayJalali() => _jalaliOf(_now());

  /// A civil date as the portal's `yyyy/MM/dd` Jalali string.
  static String _jalaliOf(DateTime date) {
    final jalali = toJalali(date);
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

  /// Reads the buy page filtered to [date], returning its HTML.
  Future<String> _readBuyPage(Session session, DateTime date) async {
    final wanted = _jalaliOf(date);
    final first = await transport.get(session.account, _Paths.basketBuy);
    if (CullinanParser.buyPageDate(first.body) == wanted) return first.body;

    final filtered = await transport.post(
      session.account,
      _Paths.basketBuy,
      body: {
        '__VIEWSTATE': hiddenFieldValue(first.body, '__VIEWSTATE'),
        '__VIEWSTATEGENERATOR':
            hiddenFieldValue(first.body, '__VIEWSTATEGENERATOR'),
        '__EVENTTARGET': '',
        '__EVENTARGUMENT': '',
        'ctl00\$cphMain\$txtDate': wanted,
        'ctl00\$cphMain\$imgbtnGoToDate.x': '1',
        'ctl00\$cphMain\$imgbtnGoToDate.y': '1',
      },
    );
    if (filtered.looksLikeLoginPage) {
      throw const LoginRejectedException('نشست منقضی شده است.');
    }
    return filtered.body;
  }

  /// Submits the buy page's form for one listing.
  ///
  /// The outcome is decided by **the row's amount**, not by whether the option
  /// disappeared. Verified live 2026-10-20 against the response to a real
  /// purchase: the bought option is still offered afterwards, and what changes
  /// is that its row becomes checked and its مبلغ خرید cell becomes non-zero.
  /// A client that tested "the option is gone" would report a completed,
  /// irreversible purchase as a failure and keep hunting.
  Future<ClaimResult> _submitBasketRow(
    Session session,
    String html,
    _ListingParts parts,
  ) async {
    final offered = CullinanParser.parseBasket(
      html,
      parts.date,
    ).where((l) => l.option.id == parts.optionId).toList();
    if (offered.isEmpty) {
      return const ClaimRejected('این آگهی دیگر در دسترس نیست.');
    }

    // The hall must be one the page actually offers for this dish. Posting a
    // hallucinated hall would be a request the portal rejects at best, and an
    // unintended purchase at worst.
    if (!offered.any((l) => l.hall.id == parts.hallId)) {
      return const ClaimRejected('این آگهی در سالن انتخاب‌شده موجود نیست.');
    }

    final body = CullinanParser.claimFormBody(
      html,
      listingId: parts.optionId,
      hallId: parts.hallId,
      date: _jalaliOf(parts.date),
    );

    final response = await transport.post(
      session.account,
      _Paths.basketBuy,
      body: body,
    );

    if (response.looksLikeLoginPage) {
      return const ClaimRejected('نشست منقضی شده است.');
    }

    final error = _basketError(response.body);
    if (error != null) {
      return ClaimRejected(error);
    }

    // The amount is the only trustworthy success signal.
    final hold = CullinanParser.heldOnBuyPage(response.body, parts.optionId);
    if (hold != null && hold.isHeld) {
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

    // The page neither reported an error nor showed the meal as held. That is
    // not proof of failure — the response may not have rendered the final
    // state — so it must not be reported as a rejection, which would invite a
    // second, irreversible purchase.
    return const ClaimAmbiguous('پاسخ سامانه نتیجه خرید را روشن نکرد.');
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
  if (parts.length != 4) return null;

  final date = DateTime.tryParse(parts[0]);
  if (date == null) return null;

  final slot = MealSlot.values.where((s) => s.name == parts[1]).firstOrNull;
  if (slot == null) return null;

  final hallId = parts[2];
  if (hallId.isEmpty) return null;

  return _ListingParts(
    date: DateTime.utc(date.year, date.month, date.day),
    slot: slot,
    hallId: hallId,
    optionId: parts[3],
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
