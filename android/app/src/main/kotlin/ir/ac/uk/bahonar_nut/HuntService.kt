package ir.ac.uk.bahonar_nut

import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder

/**
 * The foreground service that keeps a hunt alive.
 *
 * ## Why a foreground service at all
 *
 * A hunt is a burst of network requests over a window of minutes, and it has
 * to survive the screen going off and the device dozing. A background
 * `WorkManager` job is not enough: the system may defer it past the very
 * cutoff it is trying to hit. A foreground service is the only mechanism
 * Android offers that is reliably exempt from Doze.
 *
 * ## Why it is released promptly
 *
 * The spec is explicit: the service is released the moment the window closes
 * or a purchase lands. A foreground service that lingers is a battery drain
 * and a user-visible notification that will not go away, so `stopForeground`
 * is called on every exit path, including the failure ones.
 *
 * The service itself holds no logic. It keeps the process alive and asks the
 * Dart side to run; every decision about *whether* to buy belongs to the
 * domain core.
 */
class HuntService : Service() {

    companion object {
        const val ACTION_START = "ir.ac.uk.bahonar_nut.HUNT_START"
        const val ACTION_STOP = "ir.ac.uk.bahonar_nut.HUNT_STOP"
        const val EXTRA_PAYLOAD = "payload"

        /**
         * Whether the start came from the Dart side.
         *
         * The Dart side already knows it asked for the hunt, so it does not
         * need to be told, and — more importantly — it must not be *recorded*
         * as a request it still owes. Without this flag every hunt the
         * student starts by hand would leave a pending request behind, and
         * the next launch would start the hunt a second time.
         */
        const val EXTRA_FROM_DART = "fromDart"

        private const val FOREGROUND_ID = 4201

        /**
         * Starts the service, optionally with a payload describing the hunt.
         *
         * [fromDart] marks the start as the Dart side's own request. Every
         * other start is the platform asking on its own behalf, and those
         * are the ones that have to be recorded.
         */
        fun start(context: Context, payload: String?, fromDart: Boolean = false) {
            val intent = Intent(context, HuntService::class.java).apply {
                action = ACTION_START
                if (payload != null) putExtra(EXTRA_PAYLOAD, payload)
                putExtra(EXTRA_FROM_DART, fromDart)
            }
            context.startForegroundService(intent)
        }

        /** Stops the service and removes its notification. */
        fun stop(context: Context) {
            context.stopService(Intent(context, HuntService::class.java))
        }
    }

    private var notifier: ReminderNotifier? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        notifier = ReminderNotifier(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }

        // The service must post its notification within a few seconds of
        // startForegroundService, or the system kills the app for not doing so.
        startForeground(FOREGROUND_ID, notifier?.buildServiceNotification())

        val payload = intent?.getStringExtra(EXTRA_PAYLOAD)
        val fromDart = intent?.getBooleanExtra(EXTRA_FROM_DART, false) ?: false

        // The Dart side owns the hunt; it is told through the same channel the
        // rest of the platform bridge uses.
        //
        // A start the **Dart side** asked for is not recorded and not
        // announced back: the Dart side knows it asked, so a record would make
        // it start the hunt a second time on the next launch, and an
        // announcement would bounce straight back into the handler that made
        // the call.
        //
        // Every other start is the platform asking on its own behalf, and
        // those are the ones that have to be recorded. The channel is a static
        // field the activity populates, so with a dead process the
        // announcement below was a no-op: the service started, posted its
        // notification, and told nobody. The hunt never ran, and the
        // notification sat on screen claiming the app was monitoring the
        // basket.
        if (!fromDart) {
            PendingRequest.record(this, PendingRequest.KIND_HUNT, payload)

            val delivered = PlatformChannelMessenger.notifyHuntRequested(this, payload)

            if (!delivered) {
                // There was no Dart side to hand the hunt to, so nothing is
                // running. The service stops rather than sit on the screen
                // claiming to monitor the basket: a foreground service with no
                // hunt behind it is a battery drain and a notification the
                // user cannot clear. The request stays owed, and the hunt
                // starts when the app next runs.
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }

        // START_STICKY would restart the service with a null intent after a
        // kill. The hunt is re-armed by the alarm instead, so NOT_STICKY is
        // correct: a stale service restart could re-run a hunt whose window
        // has closed.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }
}

/**
 * The singleton bridge instance, so the service can reach the Dart side.
 *
 * The service and the activity live in the same process, so a static holder is
 * sufficient and avoids the ceremony of binding.
 *
 * ## The channel may be absent
 *
 * The channel is attached by the activity, so it is null whenever the process
 * is alive but the app has not been opened. Every method here therefore
 * reports whether it reached a Dart side, because a caller that was silently
 * ignored is worse than one that was told it failed.
 */
object PlatformChannelMessenger {
    private var channel: io.flutter.plugin.common.MethodChannel? = null
    private var notifier: ReminderNotifier? = null
    private var alarms: AlarmScheduler? = null

    fun attach(
        channel: io.flutter.plugin.common.MethodChannel,
        notifier: ReminderNotifier,
        alarms: AlarmScheduler,
    ) {
        this.channel = channel
        this.notifier = notifier
        this.alarms = alarms
    }

    /**
     * Asks the Dart side to run a hunt.
     *
     * Returns whether there was a Dart side to ask. A false means the request
     * was lost, and the caller must record it instead.
     */
    fun notifyHuntRequested(context: Context, payload: String?): Boolean {
        val target = channel ?: return false
        target.invokeMethod("huntRequested", payload)
        return true
    }

    /**
     * Tells the Dart side a reminder alarm fired.
     *
     * A separate method from [notifyHuntRequested], because the two mean
     * different things and the Dart side treats them differently: a hunt
     * starts a foreground service, a reminder delivers a digest and re-arms
     * itself.
     *
     * Returns whether there was a Dart side to ask.
     */
    fun notifyReminderFired(payload: String?): Boolean {
        val target = channel ?: return false
        target.invokeMethod("reminderFired", payload)
        return true
    }

    /**
     * Tells the Dart side that the alarms were cleared and must be re-armed.
     *
     * Returns whether there was a Dart side to ask.
     */
    fun notifyRebootRequired(context: Context): Boolean {
        val target = channel ?: return false
        target.invokeMethod("rebootCompleted", null)
        return true
    }

    /** Posts a notification from the Dart side. */
    fun postNotification(id: Int, title: String, body: String, deepLink: String?) {
        notifier?.post(id, title, body, deepLink)
    }
}
