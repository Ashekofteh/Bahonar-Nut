package ir.ac.uk.bahonar_nut

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var channel: MethodChannel? = null
    private var notifier: ReminderNotifier? = null
    private var alarms: AlarmScheduler? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val notifier = ReminderNotifier(this)
        val alarms = AlarmScheduler(this)
        this.notifier = notifier
        this.alarms = alarms

        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL_NAME,
        ).also { methodChannel ->
            methodChannel.setMethodCallHandler(
                PlatformChannel(this, notifier, alarms),
            )
        }

        PlatformChannelMessenger.attach(channel!!, notifier, alarms)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // A notification tap arrives here when the activity is already running.
        val deepLink = intent.getStringExtra(ReminderNotifier.EXTRA_DEEP_LINK)
        if (deepLink != null) {
            channel?.invokeMethod("deepLink", deepLink)
        }
    }

    private companion object {
        const val CHANNEL_NAME = "ir.ac.uk.bahonar_nut/platform"
    }
}
