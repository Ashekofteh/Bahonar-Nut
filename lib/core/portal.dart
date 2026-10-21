/// The portal adapter contract: the single boundary between this app and the
/// university's Cullinan portal.
///
/// This is the only portal-aware layer. Everything below it is generic transport;
/// everything above it is site-independent. When the university redesigns the
/// site, exactly this layer breaks — and the frozen interfaces here are what let
/// the domain core and UI be built and tested without the live portal.
library;

import 'dart:typed_data';

import 'models.dart';
import 'top_up.dart';

/// What the buy page reports about one option's row.
///
/// A meal is held when the row is **both** checked and charged. Neither alone
/// is enough: the portal renders every row of a just-saved grid as checked,
/// but only the bought row carries an amount.
class BasketHoldStatus {
  const BasketHoldStatus({
    required this.checked,
    required this.amountRial,
  });

  final bool checked;
  final int amountRial;

  /// True when the account actually holds this meal.
  bool get isHeld => checked && amountRial > 0;

  @override
  String toString() =>
      'BasketHoldStatus(checked=$checked, amountRial=$amountRial)';
}

/// An authenticated session. Treated as an opaque bearer credential.
class Session {
  const Session({
    required this.account,
    required this.cookies,
    required this.establishedAt,
  });

  final AccountId account;

  /// Cookie name -> value. Held as data so the transport layer owns the jar.
  final Map<String, String> cookies;
  final DateTime establishedAt;

  @override
  String toString() => 'Session($account, established ${establishedAt.toIso8601String()})';
}

/// A login challenge the portal demands before completing authentication.
///
/// The portal uses a 4-digit image CAPTCHA bound to the session at fetch time:
/// fetching the image rotates the expected answer, so a challenge must be
/// obtained and answered within one continuous session.
class LoginChallenge {
  const LoginChallenge({
    required this.imageBytes,
    required this.kind,
  });

  /// Raw image payload as served by the portal.
  ///
  /// A `Uint8List` because the image decoders (and the solver) want bytes,
  /// not a list of boxed ints.
  final Uint8List imageBytes;
  final ChallengeKind kind;

  @override
  String toString() => 'LoginChallenge(${kind.name}, ${imageBytes.length} bytes)';
}

enum ChallengeKind {
  /// Four digits, as used by the Cullinan portal.
  digits4,

  /// Some other challenge we do not know how to solve automatically.
  unknown,
}

/// The user's answer to a challenge.
class LoginChallengeResponse {
  const LoginChallengeResponse(this.answer);

  final String answer;
}

/// One page of basket inventory.
class BasketPage {
  const BasketPage({required this.listings, this.cursor});

  final List<Listing> listings;

  /// Cursor for the next page, when the portal paginates. Null means no more.
  final String? cursor;

  bool get hasMore => cursor != null;
}

/// The outcome of attempting to claim a listing.
///
/// Sealed on purpose. A claim that times out is neither success nor failure, and
/// conflating it with failure is the single most expensive bug available in this
/// project: a blind retry can buy two meals and charge the student twice. Making
/// ambiguity a distinct type means no caller can forget to handle it — the
/// compiler will insist.
sealed class ClaimResult {
  const ClaimResult();
}

/// The claim definitely succeeded.
class ClaimSucceeded extends ClaimResult {
  const ClaimSucceeded(this.reservation);

  final Reservation reservation;
}

/// The claim definitely failed, and the listing was not bought.
class ClaimRejected extends ClaimResult {
  const ClaimRejected(this.reason);

  final String reason;
}

/// We do not know whether the claim landed.
///
/// The engine must reconcile (re-fetch reservations to establish ground truth)
/// and must **never** retry the claim directly.
class ClaimAmbiguous extends ClaimResult {
  const ClaimAmbiguous(this.diagnostic);

  final String diagnostic;
}

/// The outcome of cancelling a weekly meal.
///
/// Sealed for the same reason [ClaimResult] is: a cancel that did not land
/// must never be mistaken for one that did. The three cases are genuinely
/// different, and the caller must say which one it is dealing with.
sealed class CancelOutcome {
  const CancelOutcome();
}

/// The meal is no longer held. The portal says so.
class CancelSucceeded extends CancelOutcome {
  const CancelSucceeded();
}

/// The cancel was refused: the date is past its cutoff, so the portal
/// ignored the post and the meal is still held.
///
/// This is not a failure of the request — the request was fine. It is the
/// portal's rule that a date which has locked cannot be given back (F14).
class CancelRefused extends CancelOutcome {
  const CancelRefused(this.reason);

  /// Why it was refused, in words for the student.
  final String reason;
}

/// We do not know whether the cancel landed.
///
/// The portal could not be read back, so the mirror must be left alone. The
/// meal may have been released, or it may still be held — and the next
/// authoritative read settles it.
class CancelAmbiguous extends CancelOutcome {
  const CancelAmbiguous(this.diagnostic);

  final String diagnostic;
}

/// What went wrong during login, when it goes wrong.
class LoginFailure {
  const LoginFailure(this.reason, {this.retryable = false});

  final String reason;
  final bool retryable;
}

/// A transaction recorded in the account's ledger.
class Transaction {
  const Transaction({
    required this.accountId,
    required this.type,
    required this.foodName,
    required this.slot,
    required this.weekday,
    required this.date,
    required this.count,
    required this.amountRial,
  });

  /// Which account the transaction belongs to. The portal serves one account
  /// per session, so this is set by the adapter rather than parsed from the
  /// page.
  final AccountId accountId;

  /// The portal's transaction type, e.g. `رزرو غذا` (booking) or
  /// `انصراف از رزرو غذا` (withdrawal).
  final String type;

  /// The meal, e.g. `چلو اکبرجوجه,دوغ`.
  final String foodName;

  /// The meal slot, e.g. `ناهار`.
  final MealSlot? slot;

  /// The Persian weekday, e.g. `سه شنبه`.
  final String weekday;

  /// The Jalali date, e.g. `1405/07/28`.
  final String date;

  final int count;
  final int amountRial;

  /// True when this transaction is a meal being collected rather than given up.
  ///
  /// A withdrawal (`انصراف از رزرو غذا`) means the meal was released, so it must
  /// never be reported as something the student is collecting.
  bool get isAcquisition => type.contains('رزرو') && !type.contains('انصراف');

  /// True when this transaction is a release of a meal.
  bool get isWithdrawal => type.contains('انصراف');

  @override
  String toString() => '$type | $foodName | ${slot?.name ?? weekday} | $date '
      '| $count | $amountRial';
}

/// The menus for the days that can still be booked.
///
/// The days and the menus come back together, because they are worked out
/// together: the days are counted from the portal's today, and the portal's
/// today is only known once the read that fetched the menu has been made. A
/// caller that worked the days out for itself would have to repeat that
/// reasoning — and would get it wrong whenever the two answers disagreed.
class BookableMenus {
  const BookableMenus({required this.dates, required this.menus});

  /// The days that can still be booked, in order.
  final List<DateTime> dates;

  /// One entry per meal slot served on one of [dates].
  final List<MealMenu> menus;
}

/// The portal adapter.
///
/// Implementations must:
///  - keep cookies per account with zero cross-talk between accounts;
///  - perform login as one atomic sequence (GET page -> GET challenge -> answer
///    -> POST) because the challenge binds to the session at fetch time;
///  - never emit option or hall identifiers the live page did not offer.
abstract class PortalClient {
  // --- Authentication ---

  /// Begins a login and returns a challenge when the portal demands one.
  Future<LoginChallenge?> beginLogin(String username);

  /// Completes a login. [challenge] is the response to [beginLogin]'s challenge,
  /// if one was issued.
  Future<Session> completeLogin({
    required String username,
    required String password,
    LoginChallengeResponse? challenge,
  });

  /// Refreshes an existing session, or throws if it cannot be refreshed.
  Future<Session> refresh(Session session);

  Future<void> logout(Session session);

  // --- Time ---

  /// Server time, used to construct a [`ServerClock`]. All cutoff logic depends
  /// on this being authoritative rather than the device clock.
  Future<DateTime> fetchServerTime(Session session);

  // --- Reads ---

  Future<Balance> fetchBalance(Session session);

  Future<List<MealOffering>> fetchOfferings(Session session, DateTime date);

  /// The **official menu** for [date]: the halls that serve each meal and the
  /// dishes on offer for it.
  ///
  /// This is the weekly reservation page, and it is the page the hunt's setup
  /// reads. The marketplace ([fetchBasket]) answers a different question —
  /// which meals have been *released* for sale — and its hall list is a
  /// strict subset of this one's. A hunt must be able to name a hall that has
  /// not yet released anything, because the market fills up during the hunt
  /// window.
  ///
  /// The result is one [MealMenu] per meal slot served on [date]. Slots the
  /// university does not serve that day are absent, not empty.
  Future<List<MealMenu>> fetchMenu(Session session, DateTime date);

  /// The menus for the days that can still be **booked**.
  ///
  /// The days are counted from the **portal's** today, not the device's, and
  /// the portal's today is only known once the clock has been synced — which
  /// is what this read does. So the caller cannot name the dates in
  /// advance; it asks for a number of days, and the adapter works out which
  /// days those are once the response has been read.
  ///
  /// Asking for the days one at a time instead would mean one read per day,
  /// and every request the portal sees is a request pattern.
  ///
  /// The result holds one [MealMenu] per meal slot served on one of the
  /// dates. A date the portal does not serve simply has no menu.
  Future<BookableMenus> fetchBookableMenus(
    Session session, {
    int days = 7,
  });

  Future<List<Reservation>> fetchReservations(Session session);

  /// The account's transaction history.
  ///
  /// **Necessary because a Food Basket purchase does not appear in the weekly
  /// reservation grid.** Verified by a live purchase (2026-10-19): the grids
  /// were byte-for-byte identical before and after, and the meal existed only
  /// as a ledger row. A digest that reads only the grids would report "no
  /// lunch" on a day the student had in fact bought one.
  ///
  /// The FULL history must be returned, not just the most recent row: the
  /// page's main grid holds a single row (the newest transaction) while the
  /// history lives in its `grdDetail_N` sub-grids.
  Future<List<Transaction>> fetchTransactions(Session session);

  Future<BasketPage> fetchBasket(Session session, {String? cursor});

  /// What the basket buy page says about one option's row.
  ///
  /// **This is the only way to establish whether a basket purchase landed.**
  /// A purchase does not appear in the weekly reservation grid (verified live
  /// 2026-10-19), so [fetchReservations] cannot reconcile an ambiguous claim
  /// on the basket. Returns null when the portal no longer lists the option.
  Future<BasketHoldStatus?> holdingsOnBuyPage(
    Session session, {
    required DateTime date,
    required String optionId,
  });

  // --- Writes ---

  /// Claims a listing. The distinction between the three return types is load
  /// bearing; see [ClaimResult].
  Future<ClaimResult> claim(Session session, ListingId listingId);

  Future<Reservation> reserve(Session session, MealOffering offering);

  /// Cancels the meal held for [ref].
  ///
  /// ## Why the outcome is a type and not a `void`
  ///
  /// The portal **refuses a locked date silently**: the row renders `disabled`
  /// and the server discards the post with no error label and no state change
  /// (F14). The response is a plain `200`, so a client that inferred the
  /// outcome from the status code would report a success for a cancel that
  /// changed nothing — and then hide a meal the student still holds (F63).
  ///
  /// So the outcome is established by **reading the portal back**, exactly as
  /// [reserve] does, and reported as one of three cases.
  ///
  /// ## Why the meal is named by a [MealRef] and not a string
  ///
  /// A meal id is a `(date, slot)` pair, and the pair used to travel as a
  /// string the adapter parsed back. That parse could land on the **wrong
  /// slot** without anyone noticing (F65), so the pair is carried as values
  /// now.
  Future<CancelOutcome> cancel(Session session, MealRef ref);

  // --- Top-up ---

  /// Reads the top-up page: the balance, and the banks that work.
  Future<TopUpPage> fetchTopUpPage(Session session);

  /// Starts a top-up and returns the **bank gateway** the student must pay at.
  ///
  /// The top-up is a three-step portal flow (F54), and this method performs
  /// the first two:
  ///
  ///   1. POST the amount and the chosen bank, which the portal answers with
  ///      a confirmation page;
  ///   2. POST the confirmation's `btnPay`, which the portal answers with a
  ///      **redirect to the bank's gateway**, carrying a token.
  ///
  /// The redirect is read, not followed: the gateway is unreachable from this
  /// transport (F55), and it is a browser page anyway.
  ///
  /// The returned URL must be opened in a WebView, not fetched.
  Future<Uri> beginTopUp(Session session, int amountRial, TopUpBank bank);

  /// The account's internet-payment history, newest first.
  ///
  /// This is the **proof** that a top-up landed, not the balance: the credit
  /// is applied asynchronously, after the portal re-queries the bank (F58).
  Future<List<TopUpPayment>> fetchTopUpPayments(Session session);

  // --- Navigation ---

  /// The top-up URL, or null when the portal offers no constructible link (in
  /// which case the UI navigates instead).
  Uri? topUpUrl(Session session);
}