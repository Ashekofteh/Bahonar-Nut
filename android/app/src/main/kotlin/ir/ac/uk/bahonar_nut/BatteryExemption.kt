package ir.ac.uk.bahonar_nut

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings

/**
 * The Doze exemption: whether the app is exempt from battery optimisation,
 * and how to ask for it.
 *
 * ## Why it exists
 *
 * Measured on the emulator, in deep Doze with the app killed: the app's
 * network is **blocked**. The socket does not error — it waits for the system
 * to open a maintenance window, which can be minutes away. A read that was
 * supposed to take a second took ten.
 *
 * The spec asks for exactly this mitigation (§6.3, "Survive OEM task
 * killers"), with one condition: the request must be **explicit and
 * explained** — "never a silent one". So the app states the reason in Persian
 * on the screen, and the system dialog is the user's to answer.
 *
 * ## Why it is not requested on launch
 *
 * A permission prompt the student has not earned — asked for before they know
 * what the app does, and before they have turned on the reminders it protects
 * — is a prompt they will dismiss, and dismissing it is indistinguishable from
 * not asking. So the request sits on the reminders screen, next to the switch
 * it protects, and is asked for only when the reminders are on.
 */
class BatteryExemption(private val context: Context) {

    /**
     * Whether the app is exempt from battery optimisation.
     *
     * True on anything before Android 6.0, where the concept does not exist.
     */
    fun isExempt(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val power = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
            ?: return false
        return power.isIgnoringBatteryOptimizations(context.packageName)
    }

    /**
     * Sends the user to the system setting that grants the exemption.
     *
     * Returns whether the screen was opened. Some devices do not expose it,
     * and the app still works without the exemption — the reminders are just
     * less precise.
     */
    fun request(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        if (isExempt()) return true
        return try {
            val intent = Intent(
                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                Uri.parse("package:${context.packageName}"),
            )
            context.startActivity(intent)
            true
        } catch (e: Exception) {
            // The screen may not exist on this device. The app still works
            // without the exemption; a failed request is not worth an error
            // the student can do nothing about.
            false
        }
    }
}
