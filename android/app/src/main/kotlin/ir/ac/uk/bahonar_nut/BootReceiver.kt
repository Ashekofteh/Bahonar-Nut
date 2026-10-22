package ir.ac.uk.bahonar_nut

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Re-arms the reminder alarms after a reboot or an app update.
 *
 * Android clears all alarms when the device restarts, so without this a phone
 * that was off overnight would silently fail to remind the user — and the
 * reminder is there to protect a cutoff that does not wait.
 *
 * The Dart side owns the schedule: this receiver asks it to re-arm, rather
 * than duplicating the schedule logic in Kotlin where it could drift out of
 * step with the settings the user sees.
 *
 * ## Why the request is recorded rather than delivered
 *
 * This receiver fires at boot, and **at boot the process is by definition
 * dead**. The method channel is a static field the activity populates, so a
 * call through it was a no-op — the request could never arrive even in
 * principle, and the alarms were never re-armed.
 *
 * So the request is **recorded** instead, and the Dart side picks it up when
 * it next runs. The recording happens first, and the channel is still notified
 * as well: if the process happens to be alive, the re-arm happens immediately
 * rather than at the next launch.
 */
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) {
            return
        }

        // Recorded first: the re-arm is owed, and the record is what makes it
        // owed when there is no Dart side to hand it to.
        PendingRequest.record(context, PendingRequest.KIND_REARM, null)
        PlatformChannelMessenger.notifyRebootRequired(context)
    }
}
