/// The app's platform services, wired together.
///
/// This is the composition root: it builds the portal client, the session
/// manager, the stores and the snipe engine, and hands the UI a single
/// [AppServices] to work with.
///
/// The separation matters for testability. The UI depends on the *interfaces*
/// in `lib/core`, so a test can supply in-memory stores and a fake portal,
/// while the real app supplies the Keystore-backed ones.
library;

import 'dart:async';

import '../adapter/captcha_solver.dart';
import '../adapter/cullinan_client.dart';
import '../core/account_store.dart';
import '../core/hunt_store.dart';
import '../core/local_meal_store.dart';
import '../core/platform_stores.dart';
import '../core/portal.dart';
import '../core/session.dart';
import '../core/session_manager.dart';
import '../core/snipe_engine.dart';
import '../core/time.dart';
import '../transport/http_transport.dart';
import 'hunt_service.dart';
import 'platform_bridge.dart';
import 'reminder_service.dart';

/// The portal's base address.
const String portalBaseUrl = 'https://nut.uk.ac.ir/';

/// Everything the app needs, assembled.
class AppServices {
  AppServices({
    required this.bridge,
    required this.client,
    required this.sessions,
    required this.credentialStore,
    required this.plainStore,
    required this.clock,
  });

  /// Builds the real services, backed by the Android platform.
  factory AppServices.forAndroid({
    PlatformBridge? bridge,
    DateTime Function()? now,
  }) {
    final theBridge = bridge ?? PlatformBridge();
    final clock = SyncedServerClock();
    // The transport carries the clock so every response can sync it: the
    // portal's `Date` header rides along on the reads the app was making
    // anyway, and a hunt cannot start without a trustworthy server time.
    final transport = PortalTransport(
      baseUri: Uri.parse(portalBaseUrl),
      clock: clock,
    );
    final client = CullinanPortalClient(transport: transport);
    final credentialStore = theBridge.credentialStore;
    final plainStore = theBridge.plainStore;

    return AppServices(
      bridge: theBridge,
      client: client,
      sessions: SessionManager(
        client: client,
        store: PlatformSessionStore(
          secureStore: credentialStore,
          plainStore: plainStore,
        ),
        solver: _SolverAdapter(CaptchaSolver()),
        clock: clock,
      ),
      credentialStore: credentialStore,
      plainStore: plainStore,
      clock: clock,
    );
  }

  final PlatformBridge bridge;
  final PortalClient client;
  final SessionManager sessions;
  final SecureCredentialStore credentialStore;
  final PlainStore plainStore;
  final ServerClock clock;

  /// The account list, persisted in the plain store.
  AccountStore get accountStore => PreferencesAccountStore(plainStore);

  /// The reminder configuration, persisted in the plain store.
  ReminderConfigStore get reminderConfigStore =>
      PreferencesReminderConfigStore(plainStore);

  /// The local mirror of held meals.
  ///
  /// A cache of portal state rather than a secret, so it does not need the
  /// Keystore, but it does need to survive a restart for the offline reminders
  /// to work.
  LocalMealStoreHolder get mealStore => LocalMealStoreHolder(plainStore);

  /// The hunt configuration, persisted in the plain store.
  HuntConfigStore get huntConfigStore => PreferencesHuntConfigStore(plainStore);

  /// The engine that runs the hunt.
  ///
  /// Built here rather than in the UI, so the engine outlives the screen: a
  /// hunt must keep running while the student uses the rest of the app, and
  /// the foreground service is what keeps the process alive for that.
  late final SnipeEngine engine = DefaultSnipeEngine(
    client: client,
    sessions: sessions,
    clock: clock,
  );

  /// The hunt's platform service: runs the hunt and reports its outcome.
  late final HuntService hunts = HuntService(bridge: bridge, engine: engine);

  /// The reminder service: builds digests, posts notifications, arms alarms.
  late final ReminderService reminders = ReminderService(
    bridge: bridge,
    mealStore: LocalMealStore(),
  );
}

/// Adapts the CAPTCHA solver to the [ChallengeSolver] interface.
///
/// The solver works on raw bytes and returns a richer result (including a
/// confidence); the interface takes a [LoginChallenge] and returns the answer
/// or null. The adapter keeps the solver's own API untouched, so its tests
/// stay honest, and translates at the boundary.
class _SolverAdapter implements ChallengeSolver {
  _SolverAdapter(this._solver);

  final CaptchaSolver _solver;

  @override
  Future<String?> solve(LoginChallenge challenge) async {
    final solution = _solver.solve(challenge.imageBytes);
    if (!solution.isConfident) return null;
    return solution.text;
  }
}

/// The local meal store, backed by the plain store.
class LocalMealStoreHolder {
  LocalMealStoreHolder(this._store);

  final PlainStore _store;

  /// The in-memory store the app uses.
  ///
  /// The persisted copy is the same data; this is the live view the reminders
  /// read and the sync updates.
  late final LocalMealStore store = LocalMealStore();

  static const String _key = 'meals.held';

  /// Reads the stored meals.
  Future<List<StoredMeal>> load() async {
    final raw = await _store.readString(_key);
    if (raw == null) return const [];
    try {
      final decoded = decodeMealList(raw);
      return decoded;
    } catch (_) {
      return const [];
    }
  }

  /// Replaces the stored meals.
  Future<void> save(List<StoredMeal> meals) async {
    await _store.writeString(_key, encodeMealList(meals));
  }
}
