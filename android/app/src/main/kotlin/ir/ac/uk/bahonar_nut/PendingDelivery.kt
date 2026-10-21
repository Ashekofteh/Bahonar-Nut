package ir.ac.uk.bahonar_nut

import android.content.Context
import android.content.SharedPreferences

/**
 * The deliveries the app owes, recorded where they cannot be lost.
 *
 * ## Why this exists
 *
 * A reminder alarm fires when the app may not be running. The digest is
 * composed in Dart, from the local meal mirror, so the receiver has to hand
 * the payload to the Dart side — and if the process is dead there is no Dart
 * side to hand it to. The channel is a static field populated by the
 * activity, so with a dead process the call was a no-op and the reminder was
 * **silently dropped**: the student never learned they had a lunch waiting.
 *
 * A dropped reminder is not a cosmetic failure. The reminder exists to
 * protect a cutoff that does not wait — the lunch is collectable only until
 * 15:30 — so a reminder that never arrives means a meal that is paid for
 * and never eaten.
 *
 * ## The record, not a delivery
 *
 * The native side cannot compose the digest, so it does not try. It records
 * **that a delivery is owed**, and the Dart side delivers it when it next
 * runs. The record is written in the same `SharedPreferences` the Dart side
 * reads, so no new storage and no new channel is needed.
 *
 * ## Why the record is not cleared here
 *
 * The receiver cannot know whether the Dart side later delivered the digest.
 * If it cleared the record on the way past, a delivery that was *handed to*
 * the Dart side and then lost would be forgotten. So the record is cleared
 * by the side that knows the outcome: the Dart side, after it has delivered.
 */
object PendingDelivery {

    /** The key the pending payloads are stored under. */
    private const val KEY = "reminders.pending"

    /** How many payloads are kept. A handful is plenty; the list is a queue. */
    private const val MAX_PENDING = 8

    /** The separator between the payloads in the stored string. */
    private const val SEPARATOR = "|"

    private fun preferences(context: Context): SharedPreferences =
        context.getSharedPreferences("bahonar_nut.store", Context.MODE_PRIVATE)

    /**
     * Records that a delivery is owed.
     *
     * Called from the alarm receiver, so it must work with no Dart side and
     * no running process — which is why it writes to the shared preferences
     * directly rather than going through the method channel.
     */
    fun record(context: Context, payload: String) {
        if (payload.isEmpty()) return
        val existing = read(context).toMutableList()
        // The same payload twice in a row means the alarm fired twice, and
        // the second copy would deliver the same digest again.
        if (existing.lastOrNull() == payload) return
        existing.add(payload)
        while (existing.size > MAX_PENDING) {
            existing.removeAt(0)
        }
        preferences(context).edit()
            .putString(KEY, existing.joinToString(SEPARATOR))
            .apply()
    }

    /** The deliveries owed, oldest first. */
    fun read(context: Context): List<String> {
        val raw = preferences(context).getString(KEY, null) ?: return emptyList()
        return raw.split(SEPARATOR).filter { it.isNotEmpty() }
    }

    /**
     * Removes the deliveries that have been made.
     *
     * Called by the Dart side **after** it has delivered, so a digest that
     * was composed but then lost is still owed.
     *
     * Only the named payloads are removed, and only their **last**
     * occurrence. The receiver records the payload and then hands it to the
     * Dart side in the same breath, so the copy that was just recorded is
     * the newest one — and it is the one the Dart side is answering. Removing
     * the newest leaves any *older* delivery of the same payload still owed,
     * which is right: two lunches are two reminders, and only one has been
     * delivered.
     */
    fun remove(context: Context, payloads: List<String>) {
        if (payloads.isEmpty()) return
        val remaining = read(context).toMutableList()
        for (payload in payloads) {
            val index = remaining.lastIndexOf(payload)
            if (index >= 0) {
                remaining.removeAt(index)
            }
        }
        val editor = preferences(context).edit()
        if (remaining.isEmpty()) {
            editor.remove(KEY)
        } else {
            editor.putString(KEY, remaining.joinToString(SEPARATOR))
        }
        editor.apply()
    }
}
