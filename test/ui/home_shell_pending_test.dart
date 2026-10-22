/// The shell's answer to the platform's own requests, at the level the user
/// sees it.
///
/// ## The defect
///
/// The platform can ask the Dart side to do things at moments when there is
/// no Dart side to ask:
///
///   * a **hunt** wake-up, fired by an alarm with the app killed;
///   * a **reboot**, fired by `BootReceiver` — and at boot the process is by
///     definition dead, so this one could never arrive even in principle.
///
/// Both were delivered through the method channel, whose other end only
/// exists while the activity is alive. The service started, posted its
/// notification claiming the basket was being watched, and told nobody. The
/// reboot receiver existed, was correctly declared, and re-armed nothing.
///
/// So the native side records the requests now, and the shell answers them
/// when it next runs. These tests are about the shell doing that — and about
/// a hunt request being answered *only* when that hunt is switched on.
library;

import 'package:bahonar_nut/core/account.dart';
import 'package:bahonar_nut/core/account_store.dart';
import 'package:bahonar_nut/core/hunt_config.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/reminder.dart';
import 'package:bahonar_nut/core/session_manager.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:bahonar_nut/platform/platform_bridge.dart';
import 'package:bahonar_nut/platform/platform_services.dart';
import 'package:bahonar_nut/ui/app_state.dart';
import 'package:bahonar_nut/ui/home_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/memory_stores.dart';
import '../helpers/portal_stubs.dart' show FakePortalClient;

/// The account the tests use. Fixed, so a pending request can name it.
const AccountId accountId = 'acc-test';

/// A bridge that answers with a fixed set of owed requests.
class _RequestBridge extends PlatformBridge {
  _RequestBridge(this.owed);

  /// The requests the platform is holding.
  List<String> owed;

  /// The entries the shell cleared, in the order it cleared them.
  final List<List<String>> cleared = [];

  /// The alarms the shell armed, by request code.
  final List<int> armed = [];

  /// The hunt wake-ups the shell armed, by account.
  final List<String> huntsArmed = [];

  /// The hunt wake-ups the shell cancelled, by account.
  final List<String> huntsCancelled = [];

  /// The instant each hunt wake-up was armed for.
  final Map<String, DateTime> huntWakeAt = {};

  @override
  Future<List<String>> pendingRequests() async => List.of(owed);

  @override
  Future<void> clearPendingRequests(List<String> entries) async {
    cleared.add(entries);
    owed = owed.where((e) => !entries.contains(e)).toList();
  }

  @override
  Future<void> scheduleAlarm({
    required int requestCode,
    required DateTime triggerAt,
    String? payload,
  }) async {
    armed.add(requestCode);
  }

  @override
  Future<void> cancelAlarm(int requestCode) async {}

  @override
  Future<void> scheduleHuntAlarm({
    required String accountId,
    required DateTime triggerAt,
  }) async {
    huntsArmed.add(accountId);
    huntWakeAt[accountId] = triggerAt;
  }

  @override
  Future<void> cancelHuntAlarm(String accountId) async {
    huntsCancelled.add(accountId);
    huntWakeAt.remove(accountId);
  }
}

/// A store seeded with one known account.
class _SeededAccountStore implements AccountStore {
  final SavedAccount account = SavedAccount(
    id: accountId,
    studentId: '401405035',
    alias: 'برادر',
    addedAt: DateTime.utc(2026, 10, 20),
  );

  @override
  Future<List<SavedAccount>> loadAll() async => [account];

  @override
  Future<void> save(SavedAccount account) async {}

  @override
  Future<void> remove(AccountId id) async {}
}

/// A reminder store whose configuration names the test account.
class _SeededReminderStore implements ReminderConfigStore {
  _SeededReminderStore()
      : _config = const ReminderConfig(accountIds: {accountId});

  ReminderConfig _config;

  @override
  Future<ReminderConfig> load() async => _config;

  @override
  Future<void> save(ReminderConfig config) async {
    _config = config;
  }
}

void main() {
  late FakePortalClient portal;
  late AppState state;
  late AppServices services;

  final clock = FixedServerClock.now(DateTime.utc(2026, 10, 20, 12));

  /// Builds the shell with one account and a hunt configuration.
  Future<void> pumpShell(
    WidgetTester tester, {
    required _RequestBridge bridge,
    bool huntEnabled = false,
  }) async {
    portal = FakePortalClient();

    services = AppServices(
      bridge: bridge,
      client: portal,
      sessions: SessionManager(
        client: portal,
        store: MemorySessionStore(),
        solver: NoSolver(),
        clock: clock,
      ),
      credentialStore: MemorySecureStore(),
      plainStore: MemoryPlainStore(),
      clock: clock,
    );

    state = AppState(
      accountStore: _SeededAccountStore(),
      reminderConfigStore: _SeededReminderStore(),
      huntConfigStore: InMemoryHuntConfigStore(),
      mealStore: services.mealStore.store,
    );
    await state.load();

    state.selectHuntAccount(accountId);
    await state.saveHuntConfig(
      HuntConfig(
        targetDate: DateTime.utc(2026, 10, 22),
        targetSlot: MealSlot.breakfast,
        enabled: huntEnabled,
      ),
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

  testWidgets('a reboot request re-arms the alarms', (tester) async {
    final bridge = _RequestBridge(['rearm']);

    await pumpShell(tester, bridge: bridge);

    expect(
      bridge.armed,
      isNotEmpty,
      reason: 'a reboot clears the alarms, and the re-arm is the request that '
          'must not be lost',
    );
    expect(bridge.cleared.expand((e) => e), contains('rearm'));
  });

  testWidgets('a hunt request for a switched-off hunt is not answered',
      (tester) async {
    final bridge = _RequestBridge(['hunt:$accountId']);

    await pumpShell(tester, bridge: bridge, huntEnabled: false);

    expect(
      bridge.cleared,
      isEmpty,
      reason: 'a hunt the student switched off must not start because an '
          'alarm fired, and the request stays owed rather than being dropped',
    );
  });

  testWidgets('a hunt request for a switched-on hunt is answered',
      (tester) async {
    final bridge = _RequestBridge(['hunt:$accountId']);

    await pumpShell(tester, bridge: bridge, huntEnabled: true);

    expect(
      bridge.cleared.expand((e) => e),
      contains('hunt:$accountId'),
      reason: 'a hunt the student switched on, asked for by the platform, is '
          'answered and the request is cleared',
    );
  });

  testWidgets('a hunt request for an account the app does not have is not '
      'answered', (tester) async {
    final bridge = _RequestBridge(['hunt:no-such-account']);

    await pumpShell(tester, bridge: bridge, huntEnabled: true);

    expect(
      bridge.cleared,
      isEmpty,
      reason: 'a request naming an account the app does not have cannot be '
          'acted on, so it stays owed rather than being silently dropped',
    );
  });

  testWidgets('nothing is cleared when nothing is owed', (tester) async {
    final bridge = _RequestBridge([]);

    await pumpShell(tester, bridge: bridge);

    expect(bridge.cleared, isEmpty);
  });

  group('the hunt\'s wake-up', () {
    testWidgets('a switched-on hunt is armed for its window', (tester) async {
      final bridge = _RequestBridge([]);

      await pumpShell(tester, bridge: bridge, huntEnabled: true);

      expect(bridge.huntsArmed, contains(accountId),
          reason: 'a hunt the student switched on must have a wake-up armed, '
              'or the card\'s claim that it starts by itself is false');

      // The shell's fixture targets a breakfast on 2026-10-22, which is
      // collected with the 21st's dinner — so the window opens on the 21st.
      final wakeAt = bridge.huntWakeAt[accountId]!;
      expect(wakeAt.isBefore(DateTime.utc(2026, 10, 22)), isTrue,
          reason: 'a breakfast is collected the evening before its date');
    });

    testWidgets('a switched-off hunt is not armed', (tester) async {
      final bridge = _RequestBridge([]);

      await pumpShell(tester, bridge: bridge, huntEnabled: false);

      expect(bridge.huntsArmed, isEmpty,
          reason: 'a hunt the student switched off must not start by itself');
      expect(bridge.huntsCancelled, contains(accountId),
          reason: 'and any earlier alarm for it must be cancelled');
    });

    testWidgets('a reboot re-arms the hunt\'s wake-up too', (tester) async {
      final bridge = _RequestBridge(['rearm']);

      await pumpShell(tester, bridge: bridge, huntEnabled: true);

      expect(bridge.huntsArmed, contains(accountId),
          reason: 'a reboot clears every alarm, and the hunt\'s wake-up is '
              'one of them');
    });
  });
}
