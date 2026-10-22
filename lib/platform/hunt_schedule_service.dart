/// Keeps the hunt's wake-up armed, and says when the hunt will start.
///
/// ## Why the alarm is armed here, and not by the hunt
///
/// The hunt's wake-up is what makes the card's claim true: «این شکار روشن است
/// و هنگام بازه زمانی خود شروع می‌شود» — "this hunt is on and starts by
/// itself during its time window". Before F83 nothing armed any hunt alarm
/// at all, so the switch was a switch with no consequence and the claim was
/// false.
///
/// The alarm is armed from the **configuration**, not from the hunt. The hunt
/// is a run; the alarm is a promise about the future. So the promise is made
/// when the configuration changes, and it is kept when the device reboots
/// (which clears every alarm) — the same way the reminder alarms are.
///
/// ## Why the schedule is derived rather than configured
///
/// The student does not choose *when* the hunt starts; they choose a date, a
/// meal and a window, and the start follows from those. That derivation lives
/// in `lib/core` (see [HuntSchedules]) so it can be tested on the VM, and this
/// class only moves the resulting instant across the platform boundary.
library;

import '../core/hunt_config.dart';
import '../core/hunt_schedule.dart';
import '../core/models.dart';
import '../core/time.dart';
import 'platform_bridge.dart';

/// Arms and disarms the hunt's wake-up.
class HuntScheduleService {
  HuntScheduleService({required this.bridge});

  final PlatformBridge bridge;

  /// The schedule for [config], as it stands right now.
  ///
  /// [clock] supplies the current instant. An unsynced clock cannot say
  /// whether the window has already passed, so the **device** clock is used
  /// as a stand-in — and the result is not allowed to declare the window
  /// passed. See [HuntSchedules.scheduleFor].
  HuntScheduleResult scheduleFor(HuntConfig config, ServerClock clock) {
    final synced = clock.isSynced;
    final now = synced ? clock.nowUtc : DateTime.now().toUtc();

    return HuntSchedules.scheduleFor(
      targetDate: config.targetDate,
      slot: config.targetSlot,
      windowStart: config.windowStart,
      windowEnd: config.windowEnd,
      nowUtc: now,
      clockIsSynced: synced,
    );
  }

  /// Arms the hunt's wake-up for [accountId], or disarms it.
  ///
  /// Returns the schedule that was armed, or the status that stopped it.
  ///
  /// A hunt that is **switched off** has no alarm. The switch is the student's
  /// decision that the hunt may spend money, and an armed alarm would start a
  /// hunt that the switch says must not run.
  ///
  /// The alarm is **cancelled first** in every case, so a hunt that is
  /// switched off, retargeted, or has no schedule never leaves a stale alarm
  /// behind to fire at the wrong time.
  Future<HuntScheduleResult> arm({
    required AccountId accountId,
    required HuntConfig config,
    required ServerClock clock,
  }) async {
    await bridge.cancelHuntAlarm(accountId);

    if (!config.enabled) {
      return const HuntScheduleResult(
        status: HuntScheduleStatus.disabled,
      );
    }

    final result = scheduleFor(config, clock);
    if (!result.isScheduled) return result;

    await bridge.scheduleHuntAlarm(
      accountId: accountId,
      triggerAt: result.schedule!.wakeAtUtc,
    );
    return result;
  }

  /// Cancels the hunt's wake-up for [accountId].
  Future<void> disarm(AccountId accountId) async {
    await bridge.cancelHuntAlarm(accountId);
  }
}
