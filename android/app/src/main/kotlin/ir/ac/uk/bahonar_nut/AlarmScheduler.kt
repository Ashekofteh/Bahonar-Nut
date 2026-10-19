package ir.ac.uk.bahonar_nut

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings
import androidx.core.app.ActivityCompat
import io.flutter.plugin.common.MethodChannel

/**
 * Schedules the reminder alarms.
 *
 * ## Why exact alarms
 *
 * A reminder at 10:30 that arrives at 11:20 is useless, and the window it
 * guards closes at 20:00 the same day. `AlarmManager.setExactAndAllowWhileIdle`
 * is the only API that fires at the requested minute, including in Doze.
 *
 * The permission (`SCHEDULE_EXACT_ALARM`, Android 12+) is requested **with an
 * explanation**, never silently: the user is told that exact timing is what
 * makes the reminder useful, and that the alternative — inexact alarms — can be
 * delayed by hours and may miss a cutoff entirely.
 *
 * ## The catch-up
 *
 * Exact alarms are lost when the device is off. A `WorkManager` job is
 * scheduled alongside as a backstop, and a boot receiver re-arms everything.
 * Without that, a phone that was off at 20:00 would silently fail to reserve
 * the weekend's meals.
 */
class AlarmScheduler(private val context: Context) {

    private val alarmManager: AlarmManager =
        context.getSystemService(Context.ALARM_SERVICE) as AlarmManager

    /** Whether exact alarms are currently permitted. */
    fun canScheduleExact(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        return alarmManager.canScheduleExactAlarms()
    }

    /**
     * Sends the user to the system setting that grants exact alarms.
     *
     * The request code is fixed so the setting opens once, not per call.
     */
    fun requestExactAlarmPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            result.success(true)
            return
        }
        if (canScheduleExact()) {
            result.success(true)
            return
        }
        try {
            val intent = Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM)
                .setData(android.net.Uri.parse("package:${context.packageName}"))
            context.startActivity(intent)
        } catch (e: Exception) {
            // Some devices do not expose the screen; the app still works with
            // inexact alarms, just less precisely.
        }
        result.success(false)
    }

    /** Schedules an exact alarm at [triggerAtMillis]. */
    fun scheduleExact(requestCode: Int, triggerAtMillis: Long, payload: String?) {
        val intent = Intent(context, ReminderAlarmReceiver::class.java).apply {
            action = ACTION_REMINDER
            if (payload != null) putExtra(EXTRA_PAYLOAD, payload)
        }
        val pendingIntent = PendingIntent.getBroadcast(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        if (canScheduleExact()) {
            alarmManager.setExactAndAllowWhileIdle(
                AlarmManager.RTC_WAKEUP,
                triggerAtMillis,
                pendingIntent,
            )
        } else {
            // Without the permission the alarm still fires, just not exactly.
            // A late reminder is better than none.
            alarmManager.setWindow(
                AlarmManager.RTC_WAKEUP,
                triggerAtMillis,
                INEXACT_WINDOW_MILLIS,
                pendingIntent,
            )
        }
    }

    fun cancel(requestCode: Int) {
        val intent = Intent(context, ReminderAlarmReceiver::class.java).apply {
            action = ACTION_REMINDER
        }
        val pendingIntent = PendingIntent.getBroadcast(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        alarmManager.cancel(pendingIntent)
    }

    companion object {
        const val ACTION_REMINDER = "ir.ac.uk.bahonar_nut.REMINDER"
        const val EXTRA_PAYLOAD = "payload"

        /** How much an inexact alarm may drift, in milliseconds. */
        private const val INEXACT_WINDOW_MILLIS = 10 * 60 * 1000L
    }
}
