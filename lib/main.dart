import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/account_store.dart';
import 'ui/app_state.dart';
import 'ui/home_shell.dart';
import 'ui/theme.dart';

void main() {
  runApp(const BahonarNutApp());
}

/// The application root.
class BahonarNutApp extends StatefulWidget {
  const BahonarNutApp({super.key});

  @override
  State<BahonarNutApp> createState() => _BahonarNutAppState();
}

class _BahonarNutAppState extends State<BahonarNutApp> {
  late final AppState _state;

  @override
  void initState() {
    super.initState();
    // The stores are in-memory for now. The platform-backed ones (Keystore for
    // credentials, shared preferences for the account list) land with the
    // Android shell; the domain is already written against the interfaces, so
    // swapping them is a one-line change here.
    _state = AppState(
      accountStore: InMemoryAccountStore(),
      reminderConfigStore: InMemoryReminderConfigStore(),
    )..load();
  }

  @override
  void dispose() {
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'باهنر نُت',
      debugShowCheckedModeBanner: false,
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      // Persian is right-to-left, and the layout must follow: an RTL app with an
      // LTR layout mirrors the navigation bar, the back gesture and the text
      // alignment, which is not a detail.
      locale: const Locale('fa', 'IR'),
      supportedLocales: const [Locale('fa', 'IR')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: HomeShell(state: _state),
    );
  }
}
