/// Turning a fired reminder alarm into a notification.
///
/// ## Why this exists
///
/// The alarm is scheduled by the platform and fires with the app in the
/// background — or with the app not running at all. Something has to be
/// listening for the fire and posting the digest, and that something has to
/// work without the user having opened the app.
///
/// Two mechanisms, deliberately:
///
///   * **The process is alive** (the app is open, or was backgrounded): the
///     platform's method channel carries the fired payload, and this
///     coordinator delivers the digest and re-arms the slot for tomorrow.
///   * **The process is dead** (the app was killed): the service is started
///     by the alarm itself, which brings the process up and asks for the same
///     delivery.
///
/// The second path is the one that matters most: a reminder whose whole job
/// is to protect a cutoff cannot depend on the student having opened the app.
library;

import '../core/account.dart';
import '../core/models.dart';
import '../core/reminder.dart';
import 'reminder_service.dart';

/// Delivers a fired reminder.
class ReminderDelivery {
  ReminderDelivery({
    required this.service,
    required this.accounts,
    this.config,
  });

  /// Posts the digest.
  final ReminderService service;

  /// The accounts, for their display names.
  ///
  /// The digest names each account, so it needs to know what to call them.
  ///
  /// Settable rather than final, because the account list changes as the user
  /// adds and removes accounts, and a delivery that named a removed account
  /// by its old id would be wrong.
  List<SavedAccount> accounts;

  /// The configuration to deliver against.
  ///
  /// Supplied by the caller at delivery time rather than held, so the
  /// configuration the user sees is the configuration that is delivered: a
  /// reminder must not fire for a slot the user has since switched off.
  ReminderConfig? config;

  /// The account id the current delivery is for, when there is more than one.
  ///
  /// The platform serves one account per session, so a multi-account digest
  /// needs each account's own session. The delivery is therefore per account
  /// and the platform layer is told which one to read.
  AccountId? accountId;

  /// Delivers the reminder for [slot], and re-arms it for tomorrow.
  ///
  /// Returns the text that was posted, or null when there was nothing to say.
  ///
  /// The re-arm is not optional. An exact alarm is a one-shot: without a new
  /// one, tomorrow's reminder never comes, and the user has no idea why the
  /// reminders simply stopped.
  Future<ReminderSlot?> handleFire(String? payload) async {
    final slot = ReminderService.slotFor(payload);
    if (slot == null) return null;

    final config = this.config;
    if (config == null) return null;

    // A slot that is no longer active must not fire. The user may have
    // switched it off after the alarm was armed, and a reminder the user
    // turned off is noise — and the spec says a fire already in flight
    // completes, so the check is on the *configuration*, not on the alarm.
    if (!config.isSlotActive(slot)) return null;

    final accountNames = <AccountId, String>{
      for (final account in accounts) account.id: account.resolvedName,
    };

    await service.deliver(
      slot,
      config: config,
      accountNames: accountNames,
    );

    // Re-arm for tomorrow. A one-shot alarm with no successor is a reminder
    // that works exactly once.
    await service.armSlot(slot, config);

    return slot;
  }
}
