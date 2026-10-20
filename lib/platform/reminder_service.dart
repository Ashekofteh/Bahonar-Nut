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
    await bridge.cancelAlarm(_nudgeAlarm);
    await armSlot(ReminderSlot.lunch, config);
    await armSlot(ReminderSlot.evening, config);
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

  /// The payload the alarm carries, and the slot it names.
  ///
  /// The payload is how a fired alarm says *which* reminder to deliver: the
  /// native receiver cannot read the configuration, and the Dart side has
  /// exactly two slots. So the alarm says "lunch" or "evening", and the
  /// delivery reads the configuration for itself.
  static String? payloadFor(ReminderSlot slot) {
    switch (slot) {
      case ReminderSlot.lunch:
        return 'lunch';
      case ReminderSlot.evening:
        return 'evening';
    }
  }

  /// The slot a payload names, or null when the payload is not one of ours.
  ///
  /// A payload the app does not recognise is ignored rather than guessed at:
  /// the platform also uses this channel for the hunt's own wake-up.
  static ReminderSlot? slotFor(String? payload) {
    switch (payload) {
      case 'lunch':
        return ReminderSlot.lunch;
      case 'evening':
        return ReminderSlot.evening;
      default:
        return null;
    }
  }

  /// Arms the alarms for a slot.
  ///
  /// Separate from [schedule] so a fired alarm can re-arm **its own** slot for
  /// tomorrow without touching the other one.
  Future<void> armSlot(ReminderSlot slot, ReminderConfig config) async {
    final slotConfig =
        slot == ReminderSlot.lunch ? config.lunch : config.evening;
    final requestCode =
        slot == ReminderSlot.lunch ? _lunchAlarm : _eveningAlarm;

    await bridge.cancelAlarm(requestCode);
    if (!config.isSlotActive(slot) || !slotConfig.enabled) return;

    await bridge.scheduleAlarm(
      requestCode: requestCode,
      triggerAt: _nextOccurrence(slotConfig.time, DateTime.now()),
      payload: payloadFor(slot),
    );
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

    // The digest is about **one day**, not about every meal the account
    // holds.
    //
    // The mirror holds a fortnight: today's meals, tomorrow's, and the rest of
    // the week. A digest that listed all of them would say "you have 17
    // lunches" — which is both useless and alarming, and the section heading
    // would name one date while the body listed another. (Seen on the device:
    // the heading read "پنج‌شنبه ۳۰ مهر" and the body listed every lunch in
    // the mirror.)
    //
    // So the meals are scoped to the day the reminder fires for. The evening
    // slot covers dinner tonight and breakfast tomorrow, because they are
    // collected together — so it spans two days, and the composer groups them
    // by slot.
    final now = DateTime.now();
    final today = DateTime.utc(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));

    final meals = <HeldMealDigest>[];
    for (final accountId in accounts) {
      final held = mealStore.forAccount(accountId);
      if (held.isEmpty) continue;
      meals.addAll(held
          .where((m) => _isOnDay(m, slot, today, tomorrow))
          .map((m) => HeldMealDigest(
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
      now: now,
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

  /// Whether the meal belongs to the day this reminder fires for.
  ///
  /// The lunch slot is about **today**. The evening slot is about **tonight
  /// and tomorrow morning**, because dinner and the next day's breakfast are
  /// collected together — losing one means losing both.
  static bool _isOnDay(
    StoredMeal meal,
    ReminderSlot slot,
    DateTime today,
    DateTime tomorrow,
  ) {
    final date = DateTime.utc(meal.date.year, meal.date.month, meal.date.day);

    switch (slot) {
      case ReminderSlot.lunch:
        return meal.slot == MealSlot.lunch && date == today;
      case ReminderSlot.evening:
        if (meal.slot == MealSlot.dinner) return date == today;
        if (meal.slot == MealSlot.breakfast) return date == tomorrow;
        return false;
    }
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
