import 'package:flutter/material.dart';

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
  const HomeShell({super.key, required this.state});

  final AppState state;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final screens = <Widget>[
      AccountsScreen(state: widget.state),
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
