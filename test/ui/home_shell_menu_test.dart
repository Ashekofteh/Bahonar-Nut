import 'package:bahonar_nut/core/account_store.dart';
import 'package:bahonar_nut/core/hunt_config.dart';
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
import 'package:bahonar_nut/ui/screens/hunt_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// The shell's menu read, at the level a user sees it.
///
/// The hunt screen's dish and hall lists come from the weekly menu, and the
/// shell is what reads it. These tests are about the two things that can go
/// wrong there: reading the wrong thing, and losing the reason a read failed.
void main() {
  late _FakePortalClient portal;
  late AppState state;

  /// A clock that reads as synced, so the pre-flight is not the thing under test.
  final clock = FixedServerClock.now(DateTime.utc(2026, 10, 20, 12));

  /// Builds the shell with one account and a hunt already configured.
  Future<void> pumpShell(
    WidgetTester tester, {
    required List<MealMenu> menus,
    Object? failure,
    DateTime? targetDate,
  }) async {
    portal = _FakePortalClient(menus: menus, failure: failure);

    state = AppState(
      accountStore: InMemoryAccountStore(),
      reminderConfigStore: InMemoryReminderConfigStore(),
      huntConfigStore: InMemoryHuntConfigStore(),
    );
    await state.upsertAccount(studentId: '401405035');
    await state.load();
    state.selectHuntAccount(state.accounts.first.id);
    await state.saveHuntConfig(
      HuntConfig(
        targetDate: targetDate ?? DateTime.utc(2026, 10, 22),
        targetSlot: MealSlot.breakfast,
      ),
    );

    final services = AppServices(
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

  /// Opens the hunt tab and scrolls to [text].
  ///
  /// The finder is scoped to the hunt screen: the shell keeps the other
  /// screens in an [IndexedStack], so an unscoped search would also match
  /// widgets that are on screen but offstage.
  Future<void> openHunt(WidgetTester tester, String text) async {
    await tester.tap(find.text('شکار'));
    await tester.pumpAndSettle();

    final finder = find.descendant(
      of: find.byType(HuntScreen),
      matching: find.textContaining(text),
    );
    for (var attempt = 0; attempt < 12; attempt++) {
      if (finder.evaluate().isNotEmpty) return;
      await tester.drag(
        find.descendant(
          of: find.byType(HuntScreen),
          matching: find.byType(Scrollable),
        ),
        const Offset(0, -400),
      );
      await tester.pumpAndSettle();
    }
  }

  testWidgets('the halls come from the weekly menu, and both are listed',
      (tester) async {
    await pumpShell(tester, menus: [
      MealMenu(
        date: DateTime.utc(2026, 10, 22),
        slot: MealSlot.breakfast,
        halls: const [
          Hall(id: '1', name: 'مرکزی برادران'),
          Hall(id: '2', name: 'فنی برادران'),
        ],
        dishes: const [
          MenuOption(id: '62758', name: 'تخم مرغ', priceRial: 150000),
        ],
        reservable: true,
      ),
    ]);

    await openHunt(tester, 'فنی برادران');

    expect(find.textContaining('مرکزی برادران'), findsWidgets,
        reason: 'the menu names both serving halls');
    expect(find.textContaining('فنی برادران'), findsWidgets,
        reason: 'the hall that had released nothing is the one the user '
            'reported missing');
    expect(portal.menuReads, 1, reason: 'the menu is read once for the date');
  });

  testWidgets('a failed read keeps saying why it failed', (tester) async {
    await pumpShell(
      tester,
      menus: const [],
      failure: const PortalUnreachableException('connection refused'),
    );

    await openHunt(tester, 'ارتباط با سامانه برقرار نشد');

    expect(
      find.textContaining('ارتباط با سامانه برقرار نشد'),
      findsWidgets,
      reason: 'a failed read must say it failed, not that there is no food',
    );
    expect(find.textContaining('برای این تاریخ و وعده غذایی در سامانه موجود نیست'),
        findsNothing,
        reason: 'an empty menu and a failed read are different answers');
  });

  testWidgets('a slot change does not erase the reason a read failed',
      (tester) async {
    await pumpShell(
      tester,
      menus: const [],
      failure: const PortalUnreachableException('connection refused'),
    );

    await openHunt(tester, 'ارتباط با سامانه برقرار نشد');

    // Now change the meal slot. The redraw must not replace the failure with
    // "there is no food that day": the read never succeeded, so nothing is
    // known about what the portal serves.
    await tester.scrollUntilVisible(
      find.descendant(
        of: find.byType(HuntScreen),
        matching: find.text('ناهار'),
      ),
      -200,
      scrollable: find.descendant(
        of: find.byType(HuntScreen),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(find.text('ناهار'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('ارتباط با سامانه برقرار نشد'),
      findsWidgets,
      reason: 'the reason the read failed must survive a redraw',
    );
    expect(find.textContaining('در سامانه موجود نیست'), findsNothing,
        reason: 'a failed read is not an empty menu');
  });

  testWidgets('changing the meal slot re-reads nothing', (tester) async {
    await pumpShell(tester, menus: [
      MealMenu(
        date: DateTime.utc(2026, 10, 22),
        slot: MealSlot.breakfast,
        halls: const [Hall(id: '1', name: 'مرکزی برادران')],
        dishes: const [
          MenuOption(id: '62758', name: 'تخم مرغ', priceRial: 150000),
        ],
        reservable: true,
      ),
      MealMenu(
        date: DateTime.utc(2026, 10, 22),
        slot: MealSlot.lunch,
        halls: const [
          Hall(id: '1', name: 'مرکزی برادران'),
          Hall(id: '2', name: 'فنی برادران'),
        ],
        dishes: const [
          MenuOption(id: '62759', name: 'شوید پلو', priceRial: 500000),
        ],
        reservable: true,
      ),
    ]);

    await openHunt(tester, 'فنی برادران');
    expect(portal.menuReads, 1);

    // Switch the slot to lunch, whose menu names a second hall. The chip is
    // near the top of the screen, so scroll back to it first.
    await tester.scrollUntilVisible(
      find.descendant(
        of: find.byType(HuntScreen),
        matching: find.text('ناهار'),
      ),
      -200,
      scrollable: find.descendant(
        of: find.byType(HuntScreen),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(find.text('ناهار'));
    await tester.pumpAndSettle();

    expect(portal.menuReads, 1,
        reason: 'the page carries all three meals, so a slot change is free');
  });
}

/// A portal that serves a fixed menu, or fails.
class _FakePortalClient implements PortalClient {
  _FakePortalClient({required this.menus, this.failure});

  final List<MealMenu> menus;
  final Object? failure;

  /// How many times the menu was read.
  int menuReads = 0;

  @override
  Future<List<MealMenu>> fetchMenu(Session session, DateTime date) async {
    menuReads++;
    if (failure != null) throw failure!;
    return menus;
  }

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
  Future<DateTime> fetchServerTime(Session session) async => DateTime.now().toUtc();

  @override
  Future<Balance> fetchBalance(Session session) async =>
      Balance(amountRial: 0, fetchedAt: DateTime.now().toUtc());

  @override
  Future<List<MealOffering>> fetchOfferings(Session session, DateTime date) async =>
      const [];

  @override
  Future<List<Reservation>> fetchReservations(Session session) async => const [];

  @override
  Future<List<Transaction>> fetchTransactions(Session session) async => const [];

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
  Future<void> cancel(Session session, MealId mealId) async =>
      throw UnimplementedError();
}

/// A session store that holds credentials, so a login can happen.
///
/// The read has to *establish* a session, and establishing one needs
/// credentials: the point of the test is what the shell does with a menu, not
/// what it does without a session.
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
