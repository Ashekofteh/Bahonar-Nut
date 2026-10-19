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

  // --- Writes ---

  /// Claims a listing. The distinction between the three return types is load
  /// bearing; see [ClaimResult].
  Future<ClaimResult> claim(Session session, ListingId listingId);

  Future<Reservation> reserve(Session session, MealOffering offering);

  Future<void> cancel(Session session, MealId mealId);

  // --- Navigation ---

  /// The top-up URL, or null when the portal offers no constructible link (in
  /// which case the UI navigates instead).
  Uri? topUpUrl(Session session);
}