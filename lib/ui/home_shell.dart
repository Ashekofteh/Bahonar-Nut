import 'package:flutter/material.dart';

import '../core/hunt_config.dart';
import '../core/models.dart';
import '../core/persian.dart';
import '../core/preflight.dart';
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
  Future<void> loadMarket() async {
    final accounts = widget.state.accounts;
    if (accounts.isEmpty) return;

    final session = widget.services.sessions.sessionFor(accounts.first.id);
    if (session == null) return;

    try {
      final page = await widget.services.client.fetchBasket(session);
      if (!mounted) return;

      final byName = <String, HuntDishOption>{};
      final halls = <String, Hall>{};

      for (final listing in page.listings) {
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
      });
    } catch (_) {
      // A failed read leaves the list empty, and the screen says so. A hunt
      // with no dishes would buy nothing, so there is no harm in the failure
      // being quiet here — the pre-flight is what actually guards the money.
    }
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

        final config = state.activeHuntConfig ??
            HuntConfig(targetDate: DateTime.now().toUtc());

        return HuntScreen(
          config: config,
          dishes: _marketDishes,
          halls: _marketHalls,
          isRunning: state.huntRunning,
          preflightSummary: state.huntPreflightSummary,
          preflightRefusal: state.huntPreflightRefusal,
          onConfigChanged: (updated) => state.saveHuntConfig(updated),
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

  /// Starts a hunt, after the pre-flight passes.
  Future<void> _startHunt(AccountId accountId, HuntConfig config) async {
    final engine = widget.services.engine;

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

    await engine.start(rule, hunt: config);
  }

  /// Stops a running hunt.
  Future<void> _stopHunt(AccountId accountId) async {
    await widget.services.engine.stop('hunt-$accountId');
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
