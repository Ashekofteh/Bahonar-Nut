package ir.ac.uk.bahonar_nut

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Receives the reminder alarm and hands it to the Dart side.
 *
 * ## Two different alarms, two different destinations
 *
 * The app arms two kinds of alarm, and they are not the same thing:
 *
 *  * A **reminder** alarm (`lunch`, `evening`) asks the Dart side to deliver
 *    a digest. The digest is composed in Dart, from the local meal mirror, so
 *    the receiver hands the payload to the engine and stops. If the engine is
 *    not running there is nothing to compose into, and the Dart side catches
 *    the reminder up on the next launch.
 *  * A **hunt** wake-up starts the hunt's foreground service, which keeps the
 *    process alive for the length of the hunt.
 *
 * Treating a reminder as a hunt wake-up would post the "monitoring the food
 * basket" notification and leave a foreground service running with no hunt
 * behind it — a stuck notification the user cannot clear.
 */
class ReminderAlarmReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val payload = intent.getStringExtra(AlarmScheduler.EXTRA_PAYLOAD)

        if (ReminderPayloads.isReminder(payload)) {
            PlatformChannelMessenger.notifyReminderFired(payload)
            return
        }

        HuntService.start(context, payload)
    }
}

/**
 * The payload vocabulary shared with the Dart side.
 *
 * The Dart side owns what a payload means, but the receiver has to decide
 * *which* path a payload takes before the Dart side is reachable — so the
 * split is stated here, once, and the Dart side matches it.
 */
object ReminderPayloads {
    /** The lunch digest. */
    const val LUNCH = "lunch"

    /** The evening digest (dinner and tomorrow's breakfast). */
    const val EVENING = "evening"

    /** Whether the payload names a reminder rather than a hunt. */
    fun isReminder(payload: String?): Boolean =
        payload == LUNCH || payload == EVENING
}
