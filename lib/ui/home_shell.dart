import 'package:flutter/material.dart';


import '../platform/platform_services.dart';
import '../platform/portal_sync.dart';
import 'app_state.dart';
import 'screens/accounts_screen.dart';
import 'screens/dashboard_screen.dart';
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
    ];

    return Scaffold(
      body: IndexedStack(index: _index, children: screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (index) => setState(() => _index = index),
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
        ],
      ),
    );
  }
}
