/// Application state, held in one place and shared by the screens.
///
/// Deliberately a plain [ChangeNotifier] rather than a state-management
/// package: the app has one store, and a framework would be more moving parts
/// than the problem needs. The domain logic lives in `lib/core` and is unit
/// tested there; this class only holds the results and forwards intent.
library;

import 'package:flutter/foundation.dart';

import '../core/account.dart';
import '../core/account_store.dart';
import '../core/local_meal_store.dart';
import '../core/models.dart';
import '../core/portal.dart';
import '../core/reminder.dart';
import '../core/spend_summary.dart';

/// The app's shared state.
class AppState extends ChangeNotifier {
  AppState({
    required this.accountStore,
    required this.reminderConfigStore,
    LocalMealStore? mealStore,
    this._transactions = const [],
  }) : mealStore = mealStore ?? LocalMealStore();

  /// Where saved accounts are persisted.
  final AccountStore accountStore;

  /// Where the reminder configuration is persisted.
  final ReminderConfigStore reminderConfigStore;

  /// The local mirror of what the student holds. The reminders read from here,
  /// so they work offline.
  final LocalMealStore mealStore;

  List<SavedAccount> _accounts = const [];
  ReminderConfig _reminderConfig = const ReminderConfig();
  List<Transaction> _transactions = const [];

  /// The dashboard's filter. Multi-select on both dimensions.
  SpendFilter _spendFilter = const SpendFilter();

  bool _loaded = false;
  String? _error;

  // ------------------------------------------------------------- accessors

  bool get isLoaded => _loaded;
  String? get error => _error;

  List<SavedAccount> get accounts => _accounts;
  ReminderConfig get reminderConfig => _reminderConfig;
  SpendFilter get spendFilter => _spendFilter;

  /// The transactions the dashboard is computed from.
  List<Transaction> get transactions => _transactions;

  /// The computed spend summary, honouring the current filter.
  SpendSummary get spendSummary =>
      summarise(transactions: _transactions, filter: _spendFilter);

  /// The accounts selected in the dashboard's account filter.
  Set<AccountId> get selectedAccountIds => _spendFilter.accountIds;

  /// The meal slots selected in the dashboard's slot filter.
  Set<MealSlot> get selectedSlots => _spendFilter.slots;

  /// The meals held for one account, newest first.
  List<StoredMeal> mealsFor(AccountId accountId) =>
      mealStore.forAccount(accountId);

  // --------------------------------------------------------------- loading

  /// Loads the persisted state. Safe to call more than once.
  Future<void> load() async {
    _accounts = await accountStore.loadAll();
    _reminderConfig = await reminderConfigStore.load();
    _loaded = true;
    notifyListeners();
  }

  /// Replaces the transaction history, e.g. after a live read.
  void setTransactions(List<Transaction> transactions) {
    _transactions = transactions;
    notifyListeners();
  }

  // --------------------------------------------------------------- accounts

  /// Adds an account, or updates the one with the same student ID.
  Future<void> upsertAccount({
    required String studentId,
    String? alias,
    String? profileName,
  }) async {
    final trimmedId = studentId.trim();
    if (trimmedId.isEmpty) {
      _error = 'شماره دانشجویی نمی‌تواند خالی باشد.';
      notifyListeners();
      return;
    }

    final existing = _accounts
        .where((a) => a.studentId == trimmedId)
        .cast<SavedAccount?>()
        .firstWhere((_) => true, orElse: () => null);

    final account = SavedAccount(
      id: existing?.id ?? _newAccountId(),
      studentId: trimmedId,
      alias: alias,
      profileName: profileName ?? existing?.profileName,
      addedAt: existing?.addedAt ?? DateTime.now(),
      lastLoginAt: existing?.lastLoginAt,
    );

    await accountStore.save(account);
    _accounts = await accountStore.loadAll();
    _error = null;
    notifyListeners();
  }

  /// Generates an id for a new account.
  ///
  /// A counter, not a timestamp: two accounts added within the same
  /// microsecond would otherwise collide, and the second would silently
  /// overwrite the first. That is not a theoretical concern — a widget test
  /// runs with a frozen clock, and two rapid taps on a real device can land in
  /// the same microsecond.
  String _newAccountId() {
    _idCounter++;
    return 'acc-${DateTime.now().microsecondsSinceEpoch}-$_idCounter';
  }

  int _idCounter = 0;

  /// Sets or clears an account's alias.
  Future<void> setAlias(AccountId accountId, String? alias) async {
    final index = _accounts.indexWhere((a) => a.id == accountId);
    if (index < 0) return;

    final updated = _accounts[index].withAlias(alias);
    await accountStore.save(updated);
    _accounts = await accountStore.loadAll();
    notifyListeners();
  }

  /// Records the profile name learned from the portal.
  Future<void> setProfileName(AccountId accountId, String name) async {
    final index = _accounts.indexWhere((a) => a.id == accountId);
    if (index < 0) return;

    final updated = _accounts[index].withProfileName(name);
    await accountStore.save(updated);
    _accounts = await accountStore.loadAll();
    notifyListeners();
  }

  /// Deletes an account.
  Future<void> removeAccount(AccountId accountId) async {
    await accountStore.remove(accountId);
    _accounts = await accountStore.loadAll();
    notifyListeners();
  }

  // -------------------------------------------------------------- reminders

  /// Saves the reminder configuration.
  Future<void> saveReminderConfig(ReminderConfig config) async {
    _reminderConfig = config;
    await reminderConfigStore.save(config);
    notifyListeners();
  }

  /// Toggles an account's participation in the reminders.
  Future<void> toggleReminderAccount(AccountId accountId) async {
    final next = Set<AccountId>.from(_reminderConfig.accountIds);
    if (!next.remove(accountId)) next.add(accountId);
    await saveReminderConfig(_reminderConfig.copyWith(accountIds: next));
  }

  // --------------------------------------------------------------- filtering

  /// Toggles an account in the dashboard's filter.
  void toggleSpendAccount(AccountId accountId) {
    _spendFilter = _spendFilter.toggleAccount(accountId);
    notifyListeners();
  }

  /// Toggles a meal slot in the dashboard's filter.
  void toggleSpendSlot(MealSlot slot) {
    _spendFilter = _spendFilter.toggleSlot(slot);
    notifyListeners();
  }

  /// Clears the dashboard's filter, back to showing everything.
  void clearSpendFilter() {
    _spendFilter = const SpendFilter();
    notifyListeners();
  }

  /// Reports a transient error to the user.
  void setError(String? message) {
    _error = message;
    notifyListeners();
  }
}
