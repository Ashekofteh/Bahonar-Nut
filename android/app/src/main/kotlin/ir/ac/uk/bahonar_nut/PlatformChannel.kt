package ir.ac.uk.bahonar_nut

import android.content.Context
import android.content.SharedPreferences
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The Dart <-> platform bridge.
 *
 * Deliberately narrow: the platform does storage, scheduling and notification
 * posting, and nothing else. Every decision about *what* to do stays in
 * `lib/core`, where it is unit-tested on the VM. A method channel that could
 * make decisions would put the domain rules somewhere they cannot be tested.
 */
class PlatformChannel(
    private val context: Context,
    private val notifier: ReminderNotifier,
    private val alarms: AlarmScheduler,
) : MethodChannel.MethodCallHandler {

    private val secureStore = SecureCredentialStore(context)

    private val preferences: SharedPreferences =
        context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                // --- secure store ---
                "secureRead" -> {
                    val accountId = call.argument<String>("accountId")!!
                    val stored = secureStore.read(accountId)
                    if (stored == null) {
                        result.success(null)
                    } else {
                        result.success(
                            mapOf("studentId" to stored.first, "password" to stored.second),
                        )
                    }
                }

                "secureWrite" -> {
                    secureStore.write(
                        call.argument<String>("accountId")!!,
                        call.argument<String>("studentId")!!,
                        call.argument<String>("password")!!,
                    )
                    result.success(null)
                }

                "secureDelete" -> {
                    secureStore.delete(call.argument<String>("accountId")!!)
                    result.success(null)
                }

                "secureList" -> result.success(secureStore.listAccountIds())

                // --- plain store ---
                "plainReadString" -> result.success(
                    preferences.getString(call.argument<String>("key"), null),
                )

                "plainWriteString" -> {
                    val key = call.argument<String>("key")!!
                    val value = call.argument<String>("value")
                    preferences.edit().apply {
                        if (value == null) remove(key) else putString(key, value)
                    }.apply()
                    result.success(null)
                }

                "plainReadInt" -> {
                    val value = preferences.getInt(call.argument<String>("key"), -1)
                    result.success(if (value == -1) null else value)
                }

                "plainWriteInt" -> {
                    preferences.edit()
                        .putInt(call.argument<String>("key")!!, call.argument<Int>("value")!!)
                        .apply()
                    result.success(null)
                }

                "plainReadBool" -> {
                    val value = preferences.getBoolean(call.argument<String>("key"), false)
                    result.success(value)
                }

                "plainWriteBool" -> {
                    preferences.edit()
                        .putBoolean(call.argument<String>("key")!!, call.argument<Boolean>("value")!!)
                        .apply()
                    result.success(null)
                }

                "plainRemove" -> {
                    preferences.edit().remove(call.argument<String>("key")!!).apply()
                    result.success(null)
                }

                "plainKeys" -> result.success(preferences.all.keys.toList())

                // --- pending deliveries ---
                // The deliveries the app owes, recorded by the alarm receiver
                // when the process was dead and the Dart side could not be
                // reached. The Dart side reads them, delivers them, and
                // clears them.
                "pendingDeliveries" -> result.success(
                    PendingDelivery.read(context),
                )

                "clearPendingDeliveries" -> {
                    PendingDelivery.remove(
                        context,
                        call.argument<List<String>>("payloads") ?: emptyList(),
                    )
                    result.success(null)
                }

                // --- notifications ---
                "postNotification" -> {
                    notifier.post(
                        id = call.argument<Int>("id")!!,
                        title = call.argument<String>("title")!!,
                        body = call.argument<String>("body")!!,
                        deepLink = call.argument<String>("deepLink"),
                    )
                    result.success(null)
                }

                "cancelNotification" -> {
                    notifier.cancel(call.argument<Int>("id")!!)
                    result.success(null)
                }

                "notificationPermission" -> result.success(notifier.hasPermission())

                "requestNotificationPermission" -> {
                    notifier.requestPermission(result)
                }

                // --- alarms ---
                "scheduleAlarm" -> {
                    alarms.scheduleExact(
                        requestCode = call.argument<Int>("requestCode")!!,
                        triggerAtMillis = call.argument<Long>("triggerAtMillis")!!,
                        payload = call.argument<String>("payload"),
                    )
                    result.success(null)
                }

                "cancelAlarm" -> {
                    alarms.cancel(call.argument<Int>("requestCode")!!)
                    result.success(null)
                }

                "canScheduleExactAlarms" -> result.success(alarms.canScheduleExact())

                "requestExactAlarmPermission" -> {
                    alarms.requestExactAlarmPermission(result)
                }

                // --- foreground service ---
                "startHuntService" -> {
                    // The service keeps the process alive for the length of the
                    // hunt, and asks the Dart side to run it. The payload
                    // identifies which account's hunt, so the Dart side knows
                    // whose configuration to read.
                    HuntService.start(context, call.argument<String>("payload"))
                    result.success(null)
                }

                "stopHuntService" -> {
                    // Called on every exit path, including a purchase: the
                    // service is released the moment there is nothing left to
                    // hunt for, so it never becomes a battery drain.
                    HuntService.stop(context)
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("PLATFORM_ERROR", e.message, null)
        }
    }

    private companion object {
        const val PREFERENCES_NAME = "bahonar_nut.store"
    }
}
