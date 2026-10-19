import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'platform/platform_services.dart';
import 'ui/app_state.dart';
import 'ui/home_shell.dart';
import 'ui/theme.dart';

void main() {
  runApp(const BahonarNutApp());
}

/// The application root.
class BahonarNutApp extends StatefulWidget {
  const BahonarNutApp({super.key, this.services});

  /// Injected in tests; built for Android in the app.
  final AppServices? services;

  @override
  State<BahonarNutApp> createState() => _BahonarNutAppState();
}

class _BahonarNutAppState extends State<BahonarNutApp> {
  late final AppServices _services;
  late final AppState _state;

  @override
  void initState() {
    super.initState();

    // On a device this is the Keystore-backed, preference-backed set. In a
    // test the services can be supplied, so the UI can be driven without a
    // platform.
    _services = widget.services ?? AppServices.forAndroid();

    _state = AppState(
      accountStore: _services.accountStore,
      reminderConfigStore: _services.reminderConfigStore,
      credentialStore: _services.credentialStore,
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
      home: HomeShell(state: _state, services: _services),
    );
  }
}
