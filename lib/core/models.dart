/// Domain models for the Food Basket app.
///
/// This library is platform-agnostic: it must never import `dart:io`, `dart:ui`,
/// or any `package:flutter/*`. Keeping it pure is what lets the whole domain be
/// unit-tested on the Dart VM and reused verbatim by the Windows target.
library;

/// Identifiers are opaque strings owned by the portal. Never parse them,
/// never construct them, never assume a format.
typedef MealId = String;
typedef HallId = String;
typedef OptionId = String;
typedef ListingId = String;
typedef AccountId = String;

/// The three meals served per day.
enum MealSlot { breakfast, lunch, dinner }

/// Lifecycle of a reservation the student holds.
///
/// [unknown] exists because the portal can report a state we do not recognise;
/// it must never be silently coerced into [active].
enum ReservationState { active, cancelled, consumed, sold, unknown }

/// A dining hall. Two exist today (مرکزی برادران / فنی برادران) but the count
/// is data, not a constant.
class Hall {
  const Hall({required this.id, required this.name});

  final HallId id;
  final String name;

  @override
  String toString() => 'Hall($id, $name)';
}

/// A menu option within a meal, carrying the subsidized price in Rial.
///
/// The portal also renders an unsubsidized (بدون یارانه) price tier, but that
/// tier is non-functional and is never modelled here.
class MenuOption {
  const MenuOption({
    required this.id,
    required this.name,
    required this.priceRial,
  });

  final OptionId id;
  final String name;
  final int priceRial;

  @override
  String toString() => 'MenuOption($id, $name, $priceRial Rial)';
}

/// A (date, meal, hall, option) tuple the student could reserve.
class MealOffering {
  const MealOffering({
    required this.date,
    required this.slot,
    required this.hall,
    required this.option,
    required this.reservable,
  });

  /// Date-only, in the portal's (Tehran) local frame. Time-of-day is meaningless
  /// here; the cutoff lives in [ServerClock].
  final DateTime date;
  final MealSlot slot;
  final Hall hall;
  final MenuOption option;

  /// False once the server-side cutoff has passed.
  final bool reservable;

  @override
  String toString() =>
      'MealOffering(${date.toIso8601String()} $slot ${hall.name} ${option.name})';
}

/// A reservation the student holds.
class Reservation {
  const Reservation({
    required this.id,
    required this.date,
    required this.slot,
    required this.hall,
    required this.option,
    required this.state,
  });

  final MealId id;
  final DateTime date;
  final MealSlot slot;
  final Hall hall;
  final MenuOption option;
  final ReservationState state;

  @override
  String toString() => 'Reservation($id, $slot, ${state.name})';
}

/// A listing in the Food Basket: another student's released reservation.
///
/// **Identity is composite.** The portal's buy grid renders one row per
/// (date, meal slot), and the individual purchasable meals live in the row's
/// food dropdown as separate option ids. A "listing" is therefore one option
/// within one row: `(date, slot, option id)`. There is no single portal
/// identifier for it.
///
/// Getting this wrong would silently break the tombstone set, the ledger and
/// the ranker at once, all keyed on [id], so the identity is constructed in one
/// place and reused everywhere.
class Listing {
  const Listing({
    required this.id,
    required this.date,
    required this.slot,
    required this.hall,
    required this.option,
    this.expiresAt,
  });

  /// Builds a listing and derives its composite id.
  factory Listing.composite({
    required DateTime date,
    required MealSlot slot,
    required Hall hall,
    required MenuOption option,
    DateTime? expiresAt,
  }) {
    final id = compositeListingId(date: date, slot: slot, optionId: option.id);
    return Listing(
      id: id,
      date: date,
      slot: slot,
      hall: hall,
      option: option,
      expiresAt: expiresAt,
    );
  }

  /// The composite identity of a listing: `date|slot|optionId`.
  ///
  /// Uses only the civil date, never a time component: a listing is a meal on
  /// a day, and including a time would make the same meal two different ids.
  static String compositeListingId({
    required DateTime date,
    required MealSlot slot,
    required String optionId,
  }) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}'
      '|${slot.name}'
      '|$optionId';

  final ListingId id;
  final DateTime date;
  final MealSlot slot;
  final Hall hall;
  final MenuOption option;

  /// Server-reported expiry, when the portal exposes one. Optional because the
  /// portal may not always publish it.
  final DateTime? expiresAt;

  /// The price to pay, taken from the option itself.
  int get priceRial => option.priceRial;

  @override
  String toString() => 'Listing($id, ${option.name})';
}

/// Account balance snapshot.
class Balance {
  const Balance({required this.amountRial, required this.fetchedAt});

  final int amountRial;
  final DateTime fetchedAt;

  @override
  String toString() => 'Balance($amountRial Rial)';
}