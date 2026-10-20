import 'package:bahonar_nut/core/account_store.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/platform_stores.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/core/session.dart';
import 'package:bahonar_nut/core/session_manager.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:bahonar_nut/platform/platform_bridge.dart';
import 'package:bahonar_nut/platform/platform_services.dart';
import 'package:bahonar_nut/ui/app_state.dart';
import 'package:bahonar_nut/ui/home_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// The shell's refresh, at the level a user sees it.
///
/// The defect these guard against was not a parsing bug but a **wiring** one:
/// the meal store existed in three separate instances, so the sync filled one
/// and the screens read another. The reservations screen was therefore
/// permanently empty, whatever the portal said — and the refresh button
/// appeared to work.
///
/// So the assertion here is deliberately about the *screen*, not about a store:
/// the user must see the meal after a refresh.
void main() {
  late _FakePortalClient portal;
  late AppState state;
  late AppServices services;

  /// 1405/07/28 = 2026-10-20
  final theDay = DateTime.utc(2026, 10, 20);

  final clock = FixedServerClock.now(DateTime.utc(2026, 10, 20, 12));

  Future<void> pumpShell(WidgetTester tester) async {
    portal = _FakePortalClient();

    state = AppState(
      accountStore: InMemoryAccountStore(),
      reminderConfigStore: InMemoryReminderConfigStore(),
      huntConfigStore: InMemoryHuntConfigStore(),
    );
    await state.upsertAccount(studentId: '401405035');
    await state.load();

    services = AppServices(
      bridge: PlatformBridge(),
      client: portal,
      sessions: SessionManager(
        client: portal,
        store: _MemorySessionStore(),
        solver: _NoSolver(),
        clock: clock,
      ),
      credentialStore: _MemorySecureStore(),
      plainStore: _MemoryPlainStore(),
      clock: clock,
    );

    // The state reads the **same** store the services own. This is the wiring
    // the defect broke: the state used to build its own.
    state = AppState(
      accountStore: InMemoryAccountStore(),
      reminderConfigStore: InMemoryReminderConfigStore(),
      huntConfigStore: InMemoryHuntConfigStore(),
      mealStore: services.mealStore.store,
    );
    await state.upsertAccount(studentId: '401405035');
    await state.load();

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('fa', 'IR'),
        supportedLocales: const [Locale('fa', 'IR')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: HomeShell(state: state, services: services),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Opens a bottom-navigation tab by its destination label.
  ///
  /// Scoped to the navigation bar: the app bar carries the same Persian word
  /// as the destination, so an unscoped text finder matches two widgets and
  /// the tap is ambiguous. The label rather than the icon, because a
  /// destination shows its *selected* icon while it is active, so the
  /// unselected icon is not in the tree.
  Future<void> openTab(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text(label),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Opens the reservations tab.
  Future<void> openReservations(WidgetTester tester) async {
    await openTab(tester, 'رزروها');
  }

  /// Opens the accounts tab and reads the portal.
  Future<void> refreshFromPortal(WidgetTester tester) async {
    await openTab(tester, 'حساب‌ها');
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();
  }

  testWidgets('a refresh makes the reservation appear on the screen',
      (tester) async {
    await pumpShell(tester);

    portal.reservations = [
      Reservation(
        id: 'row-lunch',
        date: theDay,
        slot: MealSlot.lunch,
        hall: const Hall(id: '1', name: 'مرکزی برادران'),
        option: const MenuOption(
            id: '62738', name: 'چلو اکبرجوجه', priceRial: 500000),
        state: ReservationState.active,
      ),
    ];

    await openReservations(tester);
    expect(find.text('هنوز رزروی برای نمایش نیست'), findsOneWidget,
        reason: 'nothing has been read yet');

    await refreshFromPortal(tester);
    await openReservations(tester);

    expect(find.text('چلو اکبرجوجه'), findsOneWidget,
        reason: 'the meal the portal reported must reach the screen');
    expect(find.text('هنوز رزروی برای نمایش نیست'), findsNothing);
  });

  testWidgets('a basket purchase reaches the reservations screen',
      (tester) async {
    // A basket purchase never appears in the weekly grid (verified live), so
    // the ledger is the only source that can show it.
    await pumpShell(tester);

    portal.transactions = [
      const Transaction(
        accountId: 'acc-1',
        type: 'رزرو غذا',
        foodName: 'چلو اکبرجوجه,دوغ',
        slot: MealSlot.lunch,
        weekday: 'سه شنبه',
        date: '1405/07/28',
        count: 1,
        amountRial: 500000,
      ),
    ];

    await refreshFromPortal(tester);
    await openReservations(tester);

    expect(find.text('چلو اکبرجوجه,دوغ'), findsOneWidget);
  });

  testWidgets('the dashboard shows the spend the ledger reports',
      (tester) async {
    await pumpShell(tester);

    portal.transactions = [
      const Transaction(
        accountId: 'acc-1',
        type: 'رزرو غذا',
        foodName: 'چلو اکبرجوجه,دوغ',
        slot: MealSlot.lunch,
        weekday: 'سه شنبه',
        date: '1405/07/28',
        count: 1,
        amountRial: 500000,
      ),
    ];

    await refreshFromPortal(tester);

    expect(state.transactions, isNotEmpty,
        reason: 'the dashboard reads the ledger the sync read');
  });
}

/// A portal that serves a fixed set of reservations and transactions.
class _FakePortalClient implements PortalClient {
  List<Reservation> reservations = const [];
  List<Transaction> transactions = const [];

  @override
  Future<LoginChallenge?> beginLogin(String username) async => null;

  @override
  Future<Session> completeLogin({
    required String username,
    required String password,
    LoginChallengeResponse? challenge,
  }) async =>
      Session(
        account: username,
        cookies: const {},
        establishedAt: DateTime.now().toUtc(),
      );

  @override
  Future<Session> refresh(Session session) async => session;

  @override
  Future<void> logout(Session session) async {}

  @override
  Future<DateTime> fetchServerTime(Session session) async =>
      DateTime.now().toUtc();

  @override
  Future<Balance> fetchBalance(Session session) async =>
      Balance(amountRial: 500000, fetchedAt: DateTime.now().toUtc());

  @override
  Future<List<MealOffering>> fetchOfferings(Session session, DateTime date) async =>
      const [];

  @override
  Future<List<MealMenu>> fetchMenu(Session session, DateTime date) async =>
      const [];

  @override
  Future<List<Reservation>> fetchReservations(Session session) async =>
      reservations;

  @override
  Future<List<Transaction>> fetchTransactions(Session session) async =>
      transactions;

  @override
  Future<BasketPage> fetchBasket(Session session, {String? cursor}) async =>
      const BasketPage(listings: []);

  @override
  Future<BasketHoldStatus?> holdingsOnBuyPage(
    Session session, {
    required DateTime date,
    required String optionId,
  }) async =>
      null;

  @override
  Uri? topUpUrl(Session session) => null;

  @override
  Future<ClaimResult> claim(Session session, ListingId listingId) async =>
      throw UnimplementedError();

  @override
  Future<Reservation> reserve(Session session, MealOffering offering) async =>
      throw UnimplementedError();

  @override
  Future<void> cancel(Session session, MealId mealId) async {}
}

/// A session store that holds credentials, so a login can happen.
class _MemorySessionStore implements SessionStore {
  StoredSession? _session;

  @override
  Future<Credentials?> readCredentials(AccountId accountId) async =>
      Credentials(studentId: accountId, password: 'not-a-real-password');

  @override
  Future<void> writeCredentials(
    AccountId accountId,
    Credentials credentials,
  ) async {}

  @override
  Future<StoredSession?> readSession(AccountId accountId) async => _session;

  @override
  Future<void> writeSession(StoredSession session) async => _session = session;

  @override
  Future<void> deleteSession(AccountId accountId) async => _session = null;

  @override
  Future<void> purge(AccountId accountId) async => _session = null;
}

/// A solver that never answers, so the login path is never taken.
class _NoSolver implements ChallengeSolver {
  @override
  Future<String?> solve(LoginChallenge challenge) async => null;
}

/// An in-memory plain store.
class _MemoryPlainStore implements PlainStore {
  final Map<String, Object> values = {};

  @override
  Future<String?> readString(String key) async => values[key] as String?;

  @override
  Future<void> writeString(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<int?> readInt(String key) async => values[key] as int?;

  @override
  Future<void> writeInt(String key, int value) async => values[key] = value;

  @override
  Future<bool?> readBool(String key) async => values[key] as bool?;

  @override
  Future<void> writeBool(String key, bool value) async => values[key] = value;

  @override
  Future<void> remove(String key) async => values.remove(key);

  @override
  Future<Set<String>> keys() async => values.keys.toSet();
}

/// An in-memory credential store.
class _MemorySecureStore implements SecureCredentialStore {
  final Map<String, Credentials> values = {};

  @override
  Future<Credentials?> read(AccountId accountId) async => values[accountId];

  @override
  Future<void> write(AccountId accountId, Credentials credentials) async =>
      values[accountId] = credentials;

  @override
  Future<void> delete(AccountId accountId) async => values.remove(accountId);

  @override
  Future<List<AccountId>> listAccountIds() async => values.keys.toList()..sort();
}
