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

        private const val FOREGROUND_ID = 4201

        /** Starts the service, optionally with a payload describing the hunt. */
        fun start(context: Context, payload: String?) {
            val intent = Intent(context, HuntService::class.java).apply {
                action = ACTION_START
                if (payload != null) putExtra(EXTRA_PAYLOAD, payload)
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
        // The Dart side owns the hunt; it is told through the same channel the
        // rest of the platform bridge uses.
        PlatformChannelMessenger.notifyHuntRequested(this, payload)

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

    /** Asks the Dart side to run a hunt. */
    fun notifyHuntRequested(context: Context, payload: String?) {
        channel?.invokeMethod("huntRequested", payload)
    }

    /**
     * Tells the Dart side a reminder alarm fired.
     *
     * A separate method from [notifyHuntRequested], because the two mean
     * different things and the Dart side treats them differently: a hunt
     * starts a foreground service, a reminder delivers a digest and re-arms
     * itself.
     */
    fun notifyReminderFired(payload: String?) {
        channel?.invokeMethod("reminderFired", payload)
    }

    /** Tells the Dart side that the alarms were cleared and must be re-armed. */
    fun notifyRebootRequired(context: Context) {
        channel?.invokeMethod("rebootCompleted", null)
    }

    /** Posts a notification from the Dart side. */
    fun postNotification(id: Int, title: String, body: String, deepLink: String?) {
        notifier?.post(id, title, body, deepLink)
    }
}
