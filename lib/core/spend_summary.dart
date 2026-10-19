/// The meal-spend metric behind the finance dashboard.
///
/// ## What the metric is
///
/// The sum of the **monetary price of the meals actually held**, per the
/// product owner's definition. It is NOT a money-in/money-out ledger: top-ups
/// and withdrawals of credit are a different thing, and are excluded.
///
/// ## The counting rule, and why a naive sum is wrong
///
/// The portal's transaction history is an **event log**, not a set of
/// possessions. The same (date, slot) can appear several times:
///
/// ```
/// 1405/07/30 lunch -> [رزرو غذا, انصراف از رزرو غذا, رزرو غذا]
/// ```
///
/// That is: booked, released, booked again. Summing every booking row would
/// count that lunch **twice**, and would count a meal that was later released
/// as still held.
///
/// The rule: **for each (account, date, slot), only the most recent event
/// counts.** If that event is a booking, the meal is held and its amount is
/// included; if it is a withdrawal, the meal was given up and is excluded.
///
/// Document order is recency order — verified against the live ledger, where
/// the newest transaction (1405/08/03, a future date) appears second, not
/// last. So "most recent" means "first in document order", not "last".
///
/// ## One caveat the UI should not overclaim
///
/// The ledger records meals **reserved**. It does not record whether the meal
/// was **eaten**. A meal reserved and then forgotten is counted here, and the
/// portal separately charges a penalty for it. So this metric is best labelled
/// "meals reserved" rather than "money spent" — the number is the cost of the
/// meals held, not a bank statement.
library;

import 'models.dart';
import 'persian.dart';
import 'portal.dart';

/// Which accounts and which meal slots a summary covers.
class SpendFilter {
  const SpendFilter({
    this.accountIds = const {},
    this.slots = const {},
  });

  /// Accounts to include. **Empty means all accounts** — the natural default
  /// for a dashboard that opens with nothing selected.
  final Set<AccountId> accountIds;

  /// Meal slots to include. **Empty means all slots.**
  final Set<MealSlot> slots;

  /// Whether [accountId] passes the account filter.
  bool includesAccount(AccountId accountId) =>
      accountIds.isEmpty || accountIds.contains(accountId);

  /// Whether [slot] passes the slot filter.
  bool includesSlot(MealSlot slot) => slots.isEmpty || slots.contains(slot);

  bool get isUnfiltered => accountIds.isEmpty && slots.isEmpty;

  /// Toggles an account in the filter.
  SpendFilter toggleAccount(AccountId accountId) {
    final next = Set<AccountId>.from(accountIds);
    if (!next.remove(accountId)) next.add(accountId);
    return SpendFilter(accountIds: next, slots: slots);
  }

  /// Toggles a meal slot in the filter.
  SpendFilter toggleSlot(MealSlot slot) {
    final next = Set<MealSlot>.from(slots);
    if (!next.remove(slot)) next.add(slot);
    return SpendFilter(accountIds: accountIds, slots: next);
  }

  @override
  String toString() => 'SpendFilter(accounts: $accountIds, slots: $slots)';
}

/// A meal that is currently held, as counted by the summary.
class SpendEntry {
  const SpendEntry({
    required this.accountId,
    required this.date,
    required this.slot,
    required this.amountRial,
    required this.foodName,
    required this.count,
  });

  final AccountId accountId;
  final DateTime date;
  final MealSlot slot;
  final int amountRial;
  final String foodName;
  final int count;

  @override
  String toString() =>
      'SpendEntry($accountId, ${date.toIso8601String().substring(0, 10)}, '
      '${slot.name}, $amountRial)';
}

/// Totals broken down by meal slot.
class SpendBySlot {
  const SpendBySlot(this.totals, this.counts);

  /// Rial per slot.
  final Map<MealSlot, int> totals;

  /// Meal count per slot.
  final Map<MealSlot, int> counts;

  int get totalRial =>
      totals.values.fold(0, (sum, value) => sum + value);

  int get totalMeals =>
      counts.values.fold(0, (sum, value) => sum + value);
}

/// The computed summary.
class SpendSummary {
  const SpendSummary({
    required this.filter,
    required this.entries,
    required this.bySlot,
    required this.byAccount,
    required this.excludedWithdrawn,
  });

  final SpendFilter filter;

  /// The meals counted, one per held (account, date, slot).
  final List<SpendEntry> entries;

  final SpendBySlot bySlot;

  /// Rial per account.
  final Map<AccountId, int> byAccount;

  /// How many (account, date, slot) pairs were excluded because their most
  /// recent event was a withdrawal — i.e. meals that were given up.
  ///
  /// Surfaced so the UI can say "excludes N released meals" rather than
  /// silently showing a smaller total.
  final int excludedWithdrawn;

  int get totalRial => entries.fold(0, (sum, e) => sum + e.amountRial);

  int get totalMeals => entries.fold(0, (sum, e) => sum + e.count);

  /// The average cost of one meal, in Rial. Zero when there are no meals.
  int get averageMealRial =>
      totalMeals == 0 ? 0 : (totalRial / totalMeals).round();
}

/// Computes the meal-spend summary from a transaction history.
///
/// [transactions] must be in the portal's order, which is **newest first**.
SpendSummary summarise({
  required List<Transaction> transactions,
  SpendFilter filter = const SpendFilter(),
}) {
  // The newest event per (account, date, slot) wins. Document order is
  // recency order, so the FIRST event seen for a key is the most recent one.
  final newest = <String, Transaction>{};
  for (final transaction in transactions) {
    final slot = transaction.slot;
    if (slot == null) continue;
    if (!filter.includesSlot(slot)) continue;
    if (!filter.includesAccount(transaction.accountId)) continue;

    final key = '${transaction.accountId}|${transaction.date}|${slot.name}';
    newest.putIfAbsent(key, () => transaction);
  }

  final entries = <SpendEntry>[];
  final totals = <MealSlot, int>{};
  final counts = <MealSlot, int>{};
  final byAccount = <AccountId, int>{};
  var excludedWithdrawn = 0;

  for (final transaction in newest.values) {
    if (!transaction.isAcquisition) {
      // The most recent event is a withdrawal: the meal was given up, so it is
      // not part of what the student is holding.
      excludedWithdrawn++;
      continue;
    }

    final slot = transaction.slot!;
    entries.add(SpendEntry(
      accountId: transaction.accountId,
      date: _parseJalali(transaction.date),
      slot: slot,
      amountRial: transaction.amountRial,
      foodName: transaction.foodName,
      count: transaction.count,
    ));

    totals[slot] = (totals[slot] ?? 0) + transaction.amountRial;
    counts[slot] = (counts[slot] ?? 0) + transaction.count;
    byAccount[transaction.accountId] =
        (byAccount[transaction.accountId] ?? 0) + transaction.amountRial;
  }

  entries.sort((a, b) {
    final byDate = b.date.compareTo(a.date);
    if (byDate != 0) return byDate;
    return a.slot.index.compareTo(b.slot.index);
  });

  return SpendSummary(
    filter: filter,
    entries: entries,
    bySlot: SpendBySlot(totals, counts),
    byAccount: byAccount,
    excludedWithdrawn: excludedWithdrawn,
  );
}

/// Parses a Jalali date into a civil date, tolerating an unparseable value.
///
/// A transaction with an unreadable date still counts towards the totals; it
/// simply cannot be placed on a day.
DateTime _parseJalali(String value) {
  final parsed = parseJalaliDate(value);
  return parsed ?? DateTime.utc(1970);
}
