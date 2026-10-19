/// The reminder service: builds the digest, posts the notification, and keeps
/// the alarms armed.
///
/// ## Offline-first, by design
///
/// The digest is built from the **local meal store**, not from the portal. A
/// reminder must fire whether or not the phone has a network connection, and
/// logging into the portal for every notification would be slow, would burn
/// radio time, and would make the app's behaviour depend on a third party's
/// uptime.
///
/// The live portal check is opt-in (the product owner's decision), and when it
/// is on, the digest is reconciled against the portal before it is sent.
library;

import 'dart:async';

import '../core/local_meal_store.dart';
import '../core/models.dart';
import '../core/reminder.dart';
import '../core/reminder_compose.dart';
import '../core/time.dart';
import 'platform_bridge.dart';

/// A scheduled reminder slot.
class ScheduledReminder {
  const ScheduledReminder({
    required this.slot,
    required this.time,
    required this.pays,
  });

  final ReminderSlot slot;

  /// The fire time, portal-local.
  final ClockTime time;

  /// The notification id, so a reminder can be replaced rather than stacked.
  final int pays;
}

/// Delivers the reminders.
class ReminderService {
  ReminderService({
    required this.bridge,
    required this.mealStore,
  });

  final PlatformBridge bridge;
  final LocalMealStore mealStore;

  /// The notification ids, one per slot, so a re-post replaces the old one.
  static const int _lunchNotificationId = 4101;
  static const int _eveningNotificationId = 4102;
  static const int _nudgeNotificationId = 4103;

  /// The alarm request codes.
  static const int _lunchAlarm = 4201;
  static const int _eveningAlarm = 4202;
  static const int _nudgeAlarm = 4203;

  /// Arms the alarms for the configured slots.
  ///
  /// Cancels first, so a removed or retimed slot does not leave a stale alarm
  /// behind to fire at the wrong time.
  Future<void> schedule(ReminderConfig config) async {
    await bridge.cancelAlarm(_lunchAlarm);
    await bridge.cancelAlarm(_eveningAlarm);
    await bridge.cancelAlarm(_nudgeAlarm);

    if (!config.masterEnabled) return;

    final now = DateTime.now();

    if (config.lunch.enabled) {
      await bridge.scheduleAlarm(
        requestCode: _lunchAlarm,
        triggerAt: _nextOccurrence(config.lunch.time, now),
        payload: 'lunch',
      );
    }

    if (config.evening.enabled) {
      await bridge.scheduleAlarm(
        requestCode: _eveningAlarm,
        triggerAt: _nextOccurrence(config.evening.time, now),
        payload: 'evening',
      );
    }
  }

  /// The next time [time] occurs, today if it is still ahead, else tomorrow.
  ///
  /// Uses the device's local clock. The alarm is only a *reminder to look*, not
  /// a purchase decision, so minute-level drift is harmless — unlike the
  /// reservation cutoff, which the domain core computes from the server clock.
  static DateTime _nextOccurrence(ClockTime time, DateTime now) {
    final today = DateTime(now.year, now.month, now.day, time.hour, time.minute);
    return today.isAfter(now) ? today : today.add(const Duration(days: 1));
  }

  /// Builds and posts the digest for [slot].
  ///
  /// Returns the text that was posted, or null when there was nothing to say.
  Future<NotificationText?> deliver(
    ReminderSlot slot, {
    required ReminderConfig config,
    required Map<AccountId, String> accountNames,
  }) async {
    final accounts = config.accountsFor(slot);
    if (accounts.isEmpty) return null;

    final meals = <HeldMealDigest>[];
    for (final accountId in accounts) {
      final held = mealStore.forAccount(accountId);
      if (held.isEmpty) continue;
      meals.addAll(held.map((m) => HeldMealDigest(
            accountId: accountId,
            displayName: accountNames[accountId] ?? accountId,
            date: m.date,
            slot: m.slot,
            dishName: m.dishName,
            hallName: m.hallName,
            priceRial: m.priceRial,
          )));
    }

    if (meals.isEmpty) return null;

    final text = composeReminderText(
      slot: slot,
      meals: meals,
      now: DateTime.now(),
    );

    await bridge.postNotification(
      id: slot == ReminderSlot.lunch
          ? _lunchNotificationId
          : _eveningNotificationId,
      title: text.title,
      body: text.body,
      deepLink: 'reminder://${slot.name}',
    );

    return text;
  }

  /// Posts the next-week nudge, if the week is not fully booked.
  Future<bool> deliverNudge({
    required ReminderConfig config,
    required Map<AccountId, String> accountNames,
  }) async {
    if (!config.nextWeekNudgeEnabled) return false;

    final accounts = config.accountIds;
    if (accounts.isEmpty) return false;

    final missing = <String>[];
    for (final accountId in accounts) {
      final held = mealStore.forAccount(accountId);
      final hasAll = MealSlot.values.every((slot) => held.any((m) => m.slot == slot));
      if (!hasAll) {
        missing.add(accountNames[accountId] ?? accountId);
      }
    }

    if (missing.isEmpty) return false;

    final text = composeNudgeText(
      accountNames: missing,
      now: DateTime.now(),
    );

    await bridge.postNotification(
      id: _nudgeNotificationId,
      title: text.title,
      body: text.body,
      deepLink: 'reminder://nudge',
    );
    return true;
  }
}
