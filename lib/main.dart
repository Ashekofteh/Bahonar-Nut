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
      huntConfigStore: _services.huntConfigStore,
      credentialStore: _services.credentialStore,
      // The **shared** mirror: the same store the portal sync writes, the
      // reservations screen reads, and the reminder service digests. A second
      // instance here would leave every one of them looking at an empty store.
      mealStore: _services.mealStore.store,
    );

    // The load is started here and **not awaited**, so the first frame is not
    // held up by the disk. The shell arms the reminder alarms when the load
    // finishes, because the configuration only exists then.
    _state.load();

    // The mirror is restored before anything reads it, so the app can answer
    // "what am I collecting" with no network — which is the whole point of
    // the offline-first design.
    _services.mealStore.restore().then((_) => _state.mealsChanged());
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
