import 'package:flutter/material.dart';

import '../core/hunt_config.dart';
import '../core/models.dart';
import '../core/persian.dart';
import '../core/preflight.dart';
import '../core/session_manager.dart' show SessionUnavailableException;
import '../core/time.dart';
import '../platform/hunt_service.dart';
import '../platform/platform_services.dart';
import '../platform/portal_sync.dart';
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

  @override
  void initState() {
    super.initState();

    _sync = PortalSync(
      client: widget.services.client,
      sessions: widget.services.sessions,
      mealStore: widget.services.mealStore.store,
    );

    // The platform can ask for a hunt.
    widget.services.bridge.onHuntRequested((payload) {
      if (!mounted) return;
      if (payload == 'refresh') {
        refreshFromPortal();
      }
    });
  }

  /// Reads the market's dishes and halls for the hunt screen.
  ///
  /// The dishes come from the **buy page**, not from the official menu: the
  /// buy page is the marketplace, and its option ids do not even match the
  /// menu's. A hunt built from the official menu would let the user choose a
  /// dish that never appears in the market.
  ///
  /// The read is for the hunt's **target date and slot**, because the market
  /// is a per-date view: the buy page is date-filtered, and a listing for
  /// another day is not what the hunt is waiting for. A hunt for tomorrow's
  /// dinner must show tomorrow's market, not today's.
  ///
  /// The read **establishes a session** rather than reusing one that happens
  /// to be lying around. A hunt screen opened on a cold start would otherwise
  /// show an empty market, and an empty market looks exactly like a market with
  /// nothing on it — a message the user would read as "no food today" rather
  /// than "the app could not reach the portal".
  Future<void> loadMarket({DateTime? date, MealSlot? slot}) async {
    final accounts = widget.state.accounts;
    if (accounts.isEmpty) return;

    final accountId = accounts.first.id;
    final targetSlot = slot ?? _currentHuntConfig?.targetSlot;
    final targetDate = date ?? _currentHuntConfig?.targetDate;

    // Remember what this read is for, so a later change of target knows the
    // list on screen is stale.
    _marketFor = _currentHuntConfig;

    try {
      final page = await widget.services.sessions.withSession(
        accountId,
        (session) => widget.services.client.fetchBasket(
          session,
          cursor: targetDate == null ? null : _jalaliOf(targetDate),
        ),
      );
      if (!mounted) return;

      final byName = <String, HuntDishOption>{};
      final halls = <String, Hall>{};

      for (final listing in page.listings) {
        // The market serves three meals a day. Only the chosen one is
        // offered, because a hunt for dinner must not be shown a breakfast
        // dish it would never buy.
        if (targetSlot != null && listing.slot != targetSlot) continue;

        halls[listing.hall.id] = listing.hall;
        final key = normalizeDishName(listing.option.name);
        byName.putIfAbsent(
          key,
          () => HuntDishOption(
            optionId: listing.option.id,
            name: listing.option.name,
            priceRial: listing.option.priceRial,
            halls: [listing.hall],
          ),
        );
      }

      setState(() {
        _marketDishes = byName.values.toList();
        _marketHalls = halls.values.toList();
        _marketError = null;
      });
    } on SessionUnavailableException catch (e) {
      _reportMarketError(e.reason);
    } catch (e) {
      _reportMarketError('خواندن سبد غذا از سامانه ممکن نشد.');
    }
  }

  /// A civil date as the portal's `yyyy/MM/dd` Jalali string.
  static String _jalaliOf(DateTime date) {
    final jalali = toJalali(date);
    return '${jalali.year}/${jalali.month.toString().padLeft(2, '0')}/'
        '${jalali.day.toString().padLeft(2, '0')}';
  }

  /// Records a failed market read, so the screen says why it is empty.
  void _reportMarketError(String message) {
    if (!mounted) return;
    setState(() {
      _marketDishes = const [];
      _marketHalls = const [];
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
      for (final account in accounts) {
        final result = await _sync.sync(account.id);
        if (!mounted) return;
        if (result.ok) {
          widget.state.setBalance(account.id, result.balanceRial ?? 0);
        } else {
          widget.state.setSyncError(account.id, result.error ?? 'خطای نامشخص');
        }
      }
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

  /// The dishes the market is offering, read from the buy page.
  ///
  /// Read once, when the hunt screen is opened: the market changes slowly
  /// compared with a hunt's window, and every read is a request pattern.
  List<HuntDishOption> _marketDishes = const [];
  List<Hall> _marketHalls = const [];

  /// Why the market could not be read, when it could not.
  ///
  /// Null means the read succeeded. An empty dish list is ambiguous on its
  /// own — it reads as "the market has nothing" — so the failure is stated
  /// rather than left for the user to infer.
  String? _marketError;

  /// The hunt configuration the market was last read for.
  ///
  /// Held so a stale read is not mistaken for a current one: the market is
  /// read for a specific (date, slot), and a read for yesterday's dinner must
  /// not be shown for today's.
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

  /// Saves a changed hunt configuration, and re-reads the market if the
  /// target moved.
  ///
  /// The market is a per-(date, slot) view, so a change of target means the
  /// dish list on screen is stale. The read is skipped when only the rate
  /// changed — the dishes do not depend on the rate, and every read is a
  /// request the portal sees.
  Future<void> _onConfigChanged(HuntConfig updated) async {
    await widget.state.saveHuntConfig(updated);

    final previous = _marketFor;
    final targetMoved = previous == null ||
        previous.targetDate != updated.targetDate ||
        previous.targetSlot != updated.targetSlot;

    if (!targetMoved) return;

    _marketFor = updated;
    await loadMarket(date: updated.targetDate, slot: updated.targetSlot);
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
