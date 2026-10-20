import 'package:flutter/material.dart';

import '../core/hunt_config.dart';
import '../core/models.dart';
import '../core/persian.dart';
import '../core/portal.dart';
import '../core/preflight.dart';
import '../core/session_manager.dart'
    show PortalUnreachableException, SessionUnavailableException;
import '../core/time.dart';
import '../platform/hunt_service.dart';
import '../platform/platform_services.dart';
import '../platform/portal_sync.dart';
import '../platform/reminder_delivery.dart';
import '../platform/reminder_service.dart';
import 'app_state.dart';
import 'screens/accounts_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/hunt_screen.dart';
import 'screens/reminders_screen.dart';
import 'screens/reservations_screen.dart';

/// The app's navigation shell.
///
/// A bottom navigation bar rather than a drawer: the app has four destinations
/// and a student checks it a few times a day, so the bar keeps them one tap away
/// instead of behind a menu.
class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.state,
    required this.services,
  });

  final AppState state;

  /// The platform services, so the screens can reach the portal.
  final AppServices services;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  /// Reads the portal for the saved accounts and refreshes the local mirror.
  late final PortalSync _sync;

  /// Delivers a fired reminder alarm.
  late final ReminderDelivery _delivery;

  @override
  void initState() {
    super.initState();

    _sync = PortalSync(
      client: widget.services.client,
      sessions: widget.services.sessions,
      mealStore: widget.services.mealStore.store,
      // The mirror is shared with the UI and the reminder service, so a
      // change has to be persisted and the screens have to redraw.
      persist: widget.services.mealStore.persist,
      onMealsChanged: widget.state.mealsChanged,
    );

    _delivery = ReminderDelivery(
      service: widget.services.reminders,
      accounts: widget.state.accounts,
    );

    // A configuration change re-arms the alarms, so the alarms always match
    // the settings the user sees.
    widget.state.onReminderConfigChanged = (config) {
      widget.services.reminders.schedule(config).catchError((_) {});
    };

    // The platform can ask for a hunt, or report that a reminder alarm fired.
    widget.services.bridge.onHuntRequested((payload) {
      if (!mounted) return;
      if (payload == 'refresh') {
        refreshFromPortal();
        return;
      }
      if (ReminderService.slotFor(payload) != null) {
        _onReminderFired(payload);
      }
    });

    // The alarms are armed from the configuration, so they exist as soon as
    // the app starts. A reminder that only works after the user has opened
    // the app once is not a reminder.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _armReminders();
    });
  }

  /// Arms the reminder alarms for the current configuration.
  Future<void> _armReminders() async {
    try {
      await widget.services.reminders.schedule(widget.state.reminderConfig);
    } catch (_) {
      // The platform may not be ready, or the exact-alarm permission may not
      // be granted. The reminder screen states the permission situation, and a
      // failed arm must not take the app down with it.
    }
  }

  /// Delivers a reminder whose alarm fired.
  Future<void> _onReminderFired(String? payload) async {
    _delivery
      ..config = widget.state.reminderConfig
      ..accounts = widget.state.accounts;
    await _delivery.handleFire(payload);
  }

  /// Reads the menu's dishes and halls for the hunt screen.
  ///
  /// The dishes and the halls come from the **official weekly menu**
  /// (`Reservation.aspx`), not from the marketplace (`FoodBasketBuy.aspx`).
  ///
  /// ## Why the menu and not the marketplace
  ///
  /// The portal answers two different questions with two different pages:
  ///
  ///  * the **weekly menu** names the halls that *serve* a meal, and the
  ///    dishes the university offers for it;
  ///  * the **buy page** names the halls that have *released* a meal into the
  ///    marketplace.
  ///
  /// The marketplace's hall list is a strict **subset** of the menu's: a
  /// hall appears there only once one of its students has released that
  /// meal. A list built from the marketplace therefore hides every hall that
  /// has not yet released anything — and a hall that has not released
  /// anything *yet* is exactly the one a hunt needs to be able to name,
  /// because the market fills up **during** the hunt window. A "prefer
  /// Central, fall back to Engineering" hunt that could not name Engineering
  /// would never use the fallback.
  ///
  /// The marketplace remains the source of **listings** — that is where a
  /// hunt's matching and claiming happen — and only there.
  ///
  /// The read is for the hunt's **target date**, because the menu is a
  /// per-date view: the portal publishes a different set of dishes every day.
  /// A hunt for tomorrow's dinner must show tomorrow's menu, not today's.
  ///
  /// The read **establishes a session** rather than reusing one that happens
  /// to be lying around. A hunt screen opened on a cold start would otherwise
  /// show an empty menu, and an empty menu looks exactly like a menu with
  /// nothing on it — a message the user would read as "no food that day"
  /// rather than "the app could not reach the portal".
  Future<void> loadMarket({DateTime? date}) async {
    final accounts = widget.state.accounts;
    if (accounts.isEmpty) return;

    final accountId = accounts.first.id;
    final targetDate = date ?? _currentHuntConfig?.targetDate;

    // Remember what this read is for, so a later change of target knows the
    // list on screen is stale.
    _marketFor = _currentHuntConfig;

    if (targetDate == null) {
      // Without a target date there is no menu to read: the weekly menu is
      // published per date, and the app must not guess which one the user
      // means.
      _reportMarketError('برای خواندن منوی غذا باید تاریخ انتخاب شود.');
      return;
    }

    try {
      final menus = await widget.services.sessions.withSession(
        accountId,
        (session) => widget.services.client.fetchMenu(session, targetDate),
      );
      if (!mounted) return;

      // The menu is read once per **date**, not per (date, slot): the page
      // carries all three meals for the day. So switching the meal slot
      // re-reads nothing — the other slots' halls and dishes are already
      // here.
      _applyMenu(menus);
    } on SessionUnavailableException catch (e) {
      _reportMarketError(e.reason);
    } on PortalUnreachableException catch (e) {
      // The portal could not be reached, and it says why. Swallowing that
      // would tell the user the menu is empty, when the truth is that the app
      // never reached the portal.
      _reportMarketError('ارتباط با سامانه برقرار نشد: ${e.message}');
    } catch (e) {
      _reportMarketError('خواندن منوی غذا از سامانه ممکن نشد.');
    }
  }

  /// Records a failed menu read, so the screen says why it is empty.
  void _reportMarketError(String message) {
    if (!mounted) return;
    setState(() {
      _marketDishes = const [];
      _marketHalls = const [];
      _menus = null;
      _marketError = message;
    });
  }

  /// Reads every account's balance and reservations from the portal.
  ///
  /// Explicit, and never a background poll: every request is a request
  /// pattern, and the portal is a shared resource.
  Future<void> refreshFromPortal() async {
    final accounts = widget.state.accounts;
    if (accounts.isEmpty) return;

    widget.state.setSyncing(true);
    try {
      final transactions = <Transaction>[];
      for (final account in accounts) {
        final result = await _sync.sync(account.id);
        if (!mounted) return;
        if (result.ok) {
          widget.state.setBalance(account.id, result.balanceRial ?? 0);
          transactions.addAll(result.transactions);
        } else {
          widget.state.setSyncError(account.id, result.error ?? 'خطای نامشخص');
        }
      }
      // The dashboard's spend metric is computed from the ledger, so it needs
      // the transactions the sync just read. Without them the chart was
      // permanently empty, whatever the portal said.
      widget.state.setTransactions(transactions);
    } finally {
      if (mounted) widget.state.setSyncing(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final screens = <Widget>[
      AccountsScreen(state: widget.state, onRefresh: refreshFromPortal),
      ReservationsScreen(state: widget.state),
      DashboardScreen(state: widget.state),
      RemindersScreen(state: widget.state),
      _huntScreen(),
    ];

    return Scaffold(
      body: IndexedStack(index: _index, children: screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (index) {
          setState(() => _index = index);
          // The market is read when the hunt is opened, not on every rebuild:
          // every read is a request pattern, and the market changes slowly
          // compared with a hunt's window.
          if (index == 4) loadMarket();
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.people_outline),
            selectedIcon: Icon(Icons.people),
            label: 'حساب‌ها',
          ),
          NavigationDestination(
            icon: Icon(Icons.restaurant_menu_outlined),
            selectedIcon: Icon(Icons.restaurant_menu),
            label: 'رزروها',
          ),
          NavigationDestination(
            icon: Icon(Icons.pie_chart_outline),
            selectedIcon: Icon(Icons.pie_chart),
            label: 'خرج',
          ),
          NavigationDestination(
            icon: Icon(Icons.notifications_outlined),
            selectedIcon: Icon(Icons.notifications),
            label: 'یادآورها',
          ),
          NavigationDestination(
            icon: Icon(Icons.search_outlined),
            selectedIcon: Icon(Icons.search),
            label: 'شکار',
          ),
        ],
      ),
    );
  }

  /// The hunt screen, with the account picker and the live market read.
  Widget _huntScreen() {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final state = widget.state;
        final accounts = state.accounts;

        if (accounts.isEmpty) {
          return Scaffold(
            appBar: AppBar(title: const Text('شکار')),
            body: const Center(child: Text('ابتدا یک حساب اضافه کنید.')),
          );
        }

        // The first account is the default, so the screen is never empty.
        final activeId = state.activeHuntAccount ?? accounts.first.id;
        if (state.activeHuntAccount == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) state.selectHuntAccount(activeId);
          });
        }

        // A hunt with no stored target starts on the portal's today, not the
        // device's. The device clock is not trusted for anything the portal
        // decides, and the date it names is one of them.
        final clock = widget.services.clock;
        final config = state.activeHuntConfig ??
            HuntConfig(
              targetDate: clock.isSynced
                  ? clock.portalTodayUtc
                  : DateTime.now().toUtc(),
            );

        return HuntScreen(
          config: config,
          dishes: _marketDishes,
          halls: _marketHalls,
          marketError: _marketError,
          targetDates: _targetDates(),
          isRunning: state.huntRunning,
          preflightSummary: state.huntPreflightSummary,
          preflightRefusal: state.huntPreflightRefusal,
          onConfigChanged: (updated) => _onConfigChanged(updated),
          onStart: () => _startHunt(activeId, config),
          onStop: () => _stopHunt(activeId),
        );
      },
    );
  }

  /// The dishes the menu is offering, read from the weekly menu.
  ///
  /// Read once per date, when the hunt screen is opened: the menu changes
  /// slowly compared with a hunt's window, and every read is a request
  /// pattern.
  List<HuntDishOption> _marketDishes = const [];
  List<Hall> _marketHalls = const [];

  /// The whole menu that was read, for every meal slot of the target date.
  ///
  /// Held because the weekly page carries all three meals for the day, so
  /// changing the meal slot is answered from here — with no request.
  List<MealMenu>? _menus;

  /// Why the menu could not be read, when it could not.
  ///
  /// Null means the read succeeded. An empty dish list is ambiguous on its
  /// own — it reads as "there is no food that day" — so the failure is stated
  /// rather than left for the user to infer.
  String? _marketError;

  /// The hunt configuration the menu was last read for.
  ///
  /// Held so a stale read is not mistaken for a current one: the menu is
  /// read for a specific date, and a read for yesterday's must not be shown
  /// for today's.
  HuntConfig? _marketFor;

  /// The hunt configuration currently being edited.
  HuntConfig? get _currentHuntConfig => widget.state.activeHuntConfig;

  /// The dates the hunt may target.
  ///
  /// Only the dates whose reservation cutoff has not passed, because a hunt
  /// for a locked date could never buy anything.
  List<DateTime> _targetDates() {
    final clock = widget.services.clock;
    if (!clock.isSynced) return const [];

    final first = clock.firstReservableDate();
    return List.generate(
      7,
      (i) => DateTime.utc(first.year, first.month, first.day + i),
    );
  }

  /// Saves a changed hunt configuration, and re-reads the menu if the target
  /// date moved.
  ///
  /// The menu is a per-**date** view: the page carries all three meals for
  /// the day, so changing the meal slot needs no request — only a change of
  /// date does. The read is also skipped when only the rate changed, for the
  /// same reason: every read is a request the portal sees.
  Future<void> _onConfigChanged(HuntConfig updated) async {
    await widget.state.saveHuntConfig(updated);

    final dateMoved = !_sameDate(_marketFor?.targetDate, updated.targetDate);

    if (!dateMoved) {
      // The date is the same, so the menu we already hold still answers the
      // question — but the *slot* may have changed, and the list on screen
      // belongs to the slot. Redraw it from the menu we have.
      _applyMenu();
      return;
    }

    await loadMarket(date: updated.targetDate);
  }

  /// Redraws the dish and hall lists from a menu.
  ///
  /// The menu holds every meal slot for the day, so a change of slot is
  /// answered from the menu already in hand — no request.
  ///
  /// With no menu in hand there is nothing to redraw, and a failed read must
  /// keep saying *why* it failed: replacing the error with "no food on that
  /// day" would tell the user the portal has nothing, when the truth is that
  /// the app could not reach it.
  void _applyMenu([List<MealMenu>? menus]) {
    if (!mounted) return;

    final list = menus ?? _menus;
    if (list == null) return;

    _menus = list;

    final config = _currentHuntConfig;
    final targetSlot = config?.targetSlot;

    final choice = targetSlot == null
        ? null
        : MenuChoice.from(list, targetSlot);

    final halls = <Hall>[
      for (final hall in choice?.halls ?? const <HuntHall>[])
        Hall(id: hall.id, name: hall.name),
    ];
    final dishes = <HuntDishOption>[
      for (final dish in choice?.dishes ?? const <HuntDish>[])
        HuntDishOption(
          optionId: dish.optionId,
          name: dish.name,
          priceRial: dish.priceRial,
          halls: halls,
        ),
    ];

    setState(() {
      _marketDishes = dishes;
      _marketHalls = halls;
      _marketFor = config;
      _marketError = null;
    });
  }

  /// Whether two civil dates are the same day.
  static bool _sameDate(DateTime? a, DateTime? b) {
    if (a == null || b == null) return a == b;
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  /// Starts a hunt, after the pre-flight passes.
  Future<void> _startHunt(AccountId accountId, HuntConfig config) async {
    final engine = widget.services.engine;
    final hunts = widget.services.hunts;

    // The ban risk is acknowledged before the hunt starts, not after: a rate
    // below ten seconds is a decision, and the decision is the user's.
    if (config.rate.needsRiskAcknowledgement && !config.riskAcknowledged) {
      final accepted = await confirmRiskAcknowledgement(
        context,
        interval: config.rate.peakInterval,
        projectedRequests: config.projectedRequests(),
      );
      if (!accepted) return;
      await widget.state.saveHuntConfig(config.copyWith(riskAcknowledged: true));
    }

    final rule = config.toRule(id: 'hunt-$accountId', account: accountId);

    final verdict = await engine.preflight(rule, hunt: config);
    if (!mounted) return;

    if (!verdict.passed) {
      widget.state.setHuntPreflight(
        refusal: _describeFailures(verdict.failures),
      );
      return;
    }

    widget.state.setHuntPreflight(summary: _describeReady(config));
    widget.state.setHuntRunning(true);

    // The listener must be in place before the hunt starts: the purchase
    // notification is posted from it, and a hunt that wins in its first
    // second must not find the listener missing.
    engine.listener = HuntNotifier(service: hunts, accountId: accountId);

    await hunts.start(accountId: accountId, config: config);
  }

  /// Stops a running hunt.
  Future<void> _stopHunt(AccountId accountId) async {
    await widget.services.hunts.stop(accountId);
    widget.state.setHuntRunning(false);
  }

  /// The Persian text for a pre-flight refusal.
  String _describeFailures(List<PreflightFailure> failures) {
    if (failures.contains(PreflightFailure.alreadyBooked)) {
      return 'برای این تاریخ و وعده، غذای دیگری در حساب شما ثبت شده است. '
          'شکار متوقف شد تا غذای تکراری نخرید.';
    }
    if (failures.contains(PreflightFailure.insufficientFunds)) {
      return 'موجودی حساب برای خرید همه غذاهای فهرست اولویت کافی نیست.';
    }
    if (failures.contains(PreflightFailure.holdingsUnreadable)) {
      return 'وضعیت رزروهای فعلی خوانده نشد، پس شکار شروع نشد.';
    }
    if (failures.contains(PreflightFailure.balanceUnreadable)) {
      return 'موجودی حساب خوانده نشد، پس شکار شروع نشد.';
    }
    if (failures.contains(PreflightFailure.clockUnsynced)) {
      return 'ساعت سرور همگام نشده است، پس شکار شروع نشد.';
    }
    if (failures.contains(PreflightFailure.noSession)) {
      return 'ورود به سامانه ممکن نشد، پس شکار شروع نشد.';
    }
    if (failures.contains(PreflightFailure.noPreferences)) {
      return 'هیچ غذایی انتخاب نشده است.';
    }
    return 'پیش‌نیازها برقرار نبود.';
  }

  /// The Persian summary of a ready hunt.
  String _describeReady(HuntConfig config) {
    final dishes = config.dishPriority.map((d) => d.name).join('، ');
    final halls = config.hallPriority.isEmpty
        ? 'هر سلفی'
        : config.hallPriority.map((h) => h.name).join('، ');
    return 'آماده: $dishes — $halls — حدود '
        '${toPersianDigits(config.projectedRequests())} درخواست.';
  }
}
