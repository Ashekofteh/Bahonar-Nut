package ir.ac.uk.bahonar_nut

import android.content.Context
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor.DartEntrypoint
import io.flutter.plugin.common.MethodChannel

/**
 * Owns the Flutter engine that runs a hunt with the app closed.
 *
 * ## Why a second engine
 *
 * A hunt has to run at 16:30 whether or not the student is holding the phone.
 * The alarm wakes the service, and the service needs a Dart side to run the
 * hunt — but with the app closed there is no Dart side.
 *
 * The obvious way to get one is to spawn an isolate, and it does not work:
 * a spawned isolate's `MethodChannel` resolves to
 * `BackgroundIsolateBinaryMessenger`, which cannot receive messages and
 * throws when a handler is set on it. Only a **root isolate** gets a real
 * `defaultBinaryMessenger`.
 *
 * A second `FlutterEngine`'s Dart *is* a root isolate — the engine's
 * `GetRootIsolateToken()` returns a non-zero token for one — so its channel
 * resolves to its own messenger, and a handler registered there answers it.
 *
 * `FlutterEngine.spawn(...)` cannot be used: it is package-private and it
 * spawns *from* a live shell, which is exactly what does not exist here. The
 * public constructor creates an engine with its own VM.
 *
 * ## Why the channel is registered twice, on purpose
 *
 * The Dart side talks to the platform over one channel name. The app's own
 * engine has a handler on it (registered by `MainActivity`); this engine has
 * its **own** handler, on its own messenger. Two handlers, one channel name,
 * two messengers — so they do not collide.
 *
 * The static [PlatformChannelMessenger] stays bound to the **activity's**
 * channel: that is the one the app's own engine calls, and the hunt the
 * student started by hand goes through it.
 */
class BackgroundHuntEngine(private val context: Context) {

    companion object {
        private const val TAG = "BackgroundHuntEngine"

        /** The channel the Dart side talks over. The same name, always. */
        const val CHANNEL_NAME = "ir.ac.uk.bahonar_nut/platform"

        /**
         * The Dart library the headless hunt lives in.
         *
         * Named rather than implied: the engine runs **this** entrypoint, not
         * the app's `main`, because the app's `main` builds a widget tree and
         * shows a screen, and a background hunt has no screen.
         */
        const val ENTRYPOINT_LIBRARY = "package:bahonar_nut/background/hunt_entrypoint.dart"

        /** The function the engine calls. It takes the account id. */
        const val ENTRYPOINT_FUNCTION = "main"
    }

    private var engine: FlutterEngine? = null

    /** Whether a background engine is running. */
    val isRunning: Boolean get() = engine != null

    /**
     * Starts the background engine and runs the hunt for [accountId].
     *
     * Returns whether the engine was started. A false means the hunt could
     * not start headless — and the caller must fall back to leaving the
     * request owed, so the hunt runs the next time the app is opened. A hunt
     * that starts late is better than a hunt that never starts.
     */
    fun start(accountId: String?): Boolean {
        if (accountId.isNullOrEmpty()) {
            // There is no account to hunt for. A hunt without an account is a
            // hunt that cannot spend money, and cannot be reported either.
            return false
        }
        if (engine != null) {
            // A hunt is already running. Starting a second engine would mean
            // two engines polling the same account, which doubles the
            // request count — the thing the account is judged on.
            return true
        }

        return try {
            // The shared loader, **initialised before it is asked anything**.
            //
            // `findAppBundlePath()` is a field read — it returns
            // `flutterApplicationInfo.flutterAssetsDir`, and that field is only
            // populated by `startInitialization`. A fresh `FlutterLoader()` is
            // therefore uninitialised, and asking it for the bundle path
            // throws a NullPointerException. That is not a theoretical
            // failure: it is what the first headless device run hit, with the
            // activity never having run to initialise anything.
            //
            // The injector's loader is the one the engine itself uses, so
            // initialising it here is also what the engine would have done
            // for itself a moment later. `startInitialization` is idempotent.
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(context)
            loader.ensureInitializationComplete(context, null)

            val created = FlutterEngine(context)
            engine = created

            // The handler for **this** engine's messenger. The native
            // `PlatformChannel` is stateless, so a second instance is
            // harmless — and it is the same code, so the background hunt can
            // do everything the app can.
            val channel = MethodChannel(
                created.dartExecutor.binaryMessenger,
                CHANNEL_NAME,
            )
            channel.setMethodCallHandler(
                PlatformChannel(
                    context,
                    ReminderNotifier(context),
                    AlarmScheduler(context),
                ),
            )

            val bundlePath = loader.findAppBundlePath()
            val entrypoint = DartEntrypoint(
                bundlePath,
                ENTRYPOINT_LIBRARY,
                ENTRYPOINT_FUNCTION,
            )
            created.dartExecutor.executeDartEntrypoint(entrypoint, listOf(accountId))

            Log.i(TAG, "the background hunt engine is running for $accountId")
            true
        } catch (e: Exception) {
            // The engine could not start: the device refused, the bundle is
            // missing, or the entrypoint threw. The hunt does not run, and
            // the request stays owed.
            Log.e(TAG, "the background hunt engine could not start", e)
            destroy()
            false
        }
    }

    /**
     * Destroys the engine and releases its Dart VM.
     *
     * A second Flutter engine is a second Dart VM, and a VM held for nothing
     * is a battery drain. So the engine dies with the service that owns it.
     */
    fun destroy() {
        val current = engine ?: return
        engine = null
        try {
            current.destroy()
        } catch (e: Exception) {
            // A failure to destroy leaves a VM behind, which is unfortunate
            // but not worth crashing a service over — the process will go
            // when the service stops.
            Log.e(TAG, "the background hunt engine could not be destroyed", e)
        }
    }
}
