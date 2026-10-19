package ir.ac.uk.bahonar_nut

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Receives the reminder alarm and hands it to the Dart side.
 *
 * The receiver does as little as possible: it starts the hunt service, which
 * then does the work. Keeping the logic in the service means the alarm path and
 * the manually-started path share one implementation, so a reminder that fires
 * from the alarm behaves identically to one the user triggered.
 */
class ReminderAlarmReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val payload = intent.getStringExtra(AlarmScheduler.EXTRA_PAYLOAD)
        HuntService.start(context, payload)
    }
}
