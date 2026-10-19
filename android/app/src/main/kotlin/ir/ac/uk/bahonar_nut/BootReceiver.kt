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
 */
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) {
            return
        }
        PlatformChannelMessenger.notifyRebootRequired(context)
    }
}
