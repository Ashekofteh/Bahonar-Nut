package ir.ac.uk.bahonar_nut

import android.content.Context
import android.content.SharedPreferences

/**
 * The requests the platform made that the Dart side has not answered yet.
 *
 * ## Why this exists
 *
 * The platform can ask the Dart side to do things at moments when there is no
 * Dart side to ask:
 *
 *  * a **hunt** wake-up, fired by an alarm, with the app killed;
 *  * a **reboot**, fired by `BootReceiver` — and at boot the process is by
 *    definition dead, so this one could never reach a live channel even in
 *    principle.
 *
 * Both used to call `PlatformChannelMessenger`, whose channel is a static
 * field the *activity* populates. With a dead process the call was a no-op:
 * the request was made, believed delivered, and lost. The reboot path was
 * worse than the hunt path — the receiver existed, was correctly declared, and
 * could not re-arm anything.
 *
 * The fix is the same shape as [PendingDelivery]: the native side **records**
 * that a request was made, and the Dart side picks it up when it next runs.
 *
 * ## The record, not the action
 *
 * The native side cannot start a hunt or re-arm an alarm — both need the
 * configuration, which lives in Dart. So it records that the request was made,
 * and the Dart side does the work when it next runs.
 *
 * The record is cleared by the side that knows the outcome: the Dart side,
 * after it has acted.
 */
object PendingRequest {

    /** The key the pending requests are stored under. */
    private const val KEY = "requests.pending"

    /** A hunt should be started. */
    const val KIND_HUNT = "hunt"

    /** The alarms should be re-armed. */
    const val KIND_REARM = "rearm"

    /** The separator between the requests in the stored string. */
    private const val SEPARATOR = "|"

    private fun preferences(context: Context): SharedPreferences =
        context.getSharedPreferences("bahonar_nut.store", Context.MODE_PRIVATE)

    /**
     * Records that a request was made.
     *
     * Called from a receiver or a service, so it must work with no Dart side
     * and no running process — which is why it writes to the shared
     * preferences directly rather than going through the method channel.
     *
     * The kind is stored alongside the request, because a hunt carries the
     * account it is for and a re-arm does not.
     */
    fun record(context: Context, kind: String, payload: String?) {
        val existing = read(context).toMutableList()
        val entry = if (payload.isNullOrEmpty()) kind else "$kind:$payload"

        // The same request twice in a row means it was asked for twice, and
        // the second copy would start a second hunt. The newest copy is the
        // one that answers, so an older one is dropped rather than left to
        // start a second run.
        if (existing.lastOrNull() == entry) return
        existing.removeAll { it == entry }
        existing.add(entry)

        preferences(context).edit()
            .putString(KEY, existing.joinToString(SEPARATOR))
            .apply()
    }

    /** The requests owed, oldest first. */
    fun read(context: Context): List<String> {
        val raw = preferences(context).getString(KEY, null) ?: return emptyList()
        return raw.split(SEPARATOR).filter { it.isNotEmpty() }
    }

    /**
     * Removes the requests that have been answered.
     *
     * Called by the Dart side **after** it has acted, so a request that was
     * made but not carried out is still owed.
     */
    fun remove(context: Context, entries: List<String>) {
        if (entries.isEmpty()) return
        val remaining = read(context).toMutableList()
        remaining.removeAll { it in entries }
        val editor = preferences(context).edit()
        if (remaining.isEmpty()) {
            editor.remove(KEY)
        } else {
            editor.putString(KEY, remaining.joinToString(SEPARATOR))
        }
        editor.apply()
    }
}
