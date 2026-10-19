import 'package:flutter/material.dart';

import '../../core/persian.dart';
import '../../core/reminder.dart';
import '../../core/time.dart';
import '../app_state.dart';
import '../widgets.dart';

/// The reminders screen: when the app should speak up, and about which accounts.
///
/// The design follows the product owner's model:
///
///   * A **master switch** that turns the whole feature off. Off means no
///     alarms are scheduled at all, and the screen says so plainly rather than
///     leaving the sub-settings looking live.
///   * **Two slots** with configurable times — lunch, and the evening slot that
///     covers dinner and tomorrow's breakfast together (they are collected
///     together, so one reminder covers both).
///   * **Per-account selection**: which of the saved accounts the reminders
///     speak about.
///   * A **live portal check** as an opt-in, off by default. Off means the
///     reminders read the local store and never need to log in.
class RemindersScreen extends StatelessWidget {
  const RemindersScreen({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final config = state.reminderConfig;
        final accounts = state.accounts;

        return Scaffold(
          appBar: AppBar(title: const Text('یادآورها')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
            children: [
              _MasterSwitchCard(state: state, config: config),
              const SizedBox(height: 12),
              _SlotCard(
                state: state,
                config: config,
                slot: ReminderSlot.lunch,
                title: 'یادآور ناهار',
                covers: 'وعده ناهار',
              ),
              const SizedBox(height: 12),
              _SlotCard(
                state: state,
                config: config,
                slot: ReminderSlot.evening,
                title: 'یادآور شام و صبحانه فردا',
                covers: 'وعده شام و صبحانه فردا (با هم تحویل می‌گیرند)',
              ),
              const SizedBox(height: 12),
              _AccountsCard(state: state, config: config, accounts: accounts),
              const SizedBox(height: 12),
              _NudgeCard(state: state, config: config),
              const SizedBox(height: 12),
              const _LiveSyncCard(),
            ],
          ),
        );
      },
    );
  }
}

/// The master switch.
class _MasterSwitchCard extends StatelessWidget {
  const _MasterSwitchCard({required this.state, required this.config});

  final AppState state;
  final ReminderConfig config;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'فعال‌سازی یادآورها',
      subtitle: config.masterEnabled
          ? 'یادآورها فعال‌اند و طبق برنامه زمانی زیر ارسال می‌شوند.'
          : 'همه یادآورها خاموش‌اند و هیچ اعلانی برنامه‌ریزی نشده است.',
      trailing: Switch(
        value: config.masterEnabled,
        onChanged: (value) =>
            state.saveReminderConfig(config.copyWith(masterEnabled: value)),
      ),
      child: const SizedBox.shrink(),
    );
  }
}

/// One reminder slot: on/off, its time, and what it covers.
class _SlotCard extends StatelessWidget {
  const _SlotCard({
    required this.state,
    required this.config,
    required this.slot,
    required this.title,
    required this.covers,
  });

  final AppState state;
  final ReminderConfig config;
  final ReminderSlot slot;
  final String title;
  final String covers;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final slotConfig =
        slot == ReminderSlot.lunch ? config.lunch : config.evening;
    final enabled = config.masterEnabled && slotConfig.enabled;

    return SectionCard(
      title: title,
      subtitle: covers,
      trailing: Switch(
        value: slotConfig.enabled,
        onChanged: config.masterEnabled
            ? (value) => _saveSlot(slot, slotConfig.copyWith(enabled: value))
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: config.masterEnabled
                ? () => _pickTime(context, slot, slotConfig.time)
                : null,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: enabled
                      ? theme.colorScheme.primary.withValues(alpha: 0.4)
                      : theme.colorScheme.outlineVariant,
                ),
                color: enabled
                    ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
                    : null,
              ),
              child: Row(
                children: [
                  Icon(Icons.schedule,
                      size: 20,
                      color: enabled
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 10),
                  Text(
                    formatClockTimePersian(
                      slotConfig.time.hour,
                      slotConfig.time.minute,
                    ),
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: enabled
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  if (enabled)
                    Text(
                      'برای تغییر ضربه بزنید',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _saveSlot(ReminderSlot slot, ReminderSlotConfig updated) {
    state.saveReminderConfig(config.copyWith(
      lunch: slot == ReminderSlot.lunch ? updated : config.lunch,
      evening: slot == ReminderSlot.evening ? updated : config.evening,
    ));
  }

  Future<void> _pickTime(
    BuildContext context,
    ReminderSlot slot,
    ClockTime current,
  ) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: current.hour, minute: current.minute),
      helpText: 'زمان یادآور',
      builder: (context, child) => Directionality(
        textDirection: TextDirection.rtl,
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
          child: child!,
        ),
      ),
    );
    if (picked == null) return;

    final updated = ClockTime(picked.hour, picked.minute);
    _saveSlot(
      slot,
      slot == ReminderSlot.lunch
          ? config.lunch.copyWith(time: updated)
          : config.evening.copyWith(time: updated),
    );
  }
}

/// Which accounts the reminders speak about.
class _AccountsCard extends StatelessWidget {
  const _AccountsCard({
    required this.state,
    required this.config,
    required this.accounts,
  });

  final AppState state;
  final ReminderConfig config;
  final List<dynamic> accounts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SectionCard(
      title: 'حساب‌ها',
      subtitle: config.accountIds.isEmpty
          ? 'هیچ حسابی انتخاب نشده — تا وقتی حسابی انتخاب نکنید، یادآوری ارسال نمی‌شود.'
          : '${toPersianDigits(config.accountIds.length)} حساب انتخاب شده',
      child: accounts.isEmpty
          ? Text(
              'ابتدا یک حساب اضافه کنید.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          : Column(
              children: [
                for (final account in accounts)
                  CheckboxListTile(
                    value: config.accountIds.contains(account.id),
                    onChanged: (_) => state.toggleReminderAccount(account.id),
                    title: Text(account.resolvedName),
                    subtitle: Text(account.studentId),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
              ],
            ),
    );
  }
}

/// The next-week nudge.
class _NudgeCard extends StatelessWidget {
  const _NudgeCard({required this.state, required this.config});

  final AppState state;
  final ReminderConfig config;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'یادآور رزرو هفته آینده',
      subtitle:
          'از چهارشنبه ظهر تا پنجشنبه عصر بررسی می‌شود که وعده‌های هفته آینده رزرو شده‌اند یا نه.',
      trailing: Switch(
        value: config.nextWeekNudgeEnabled,
        onChanged: (value) => state
            .saveReminderConfig(config.copyWith(nextWeekNudgeEnabled: value)),
      ),
      child: const SizedBox.shrink(),
    );
  }
}

/// The opt-in live portal check.
class _LiveSyncCard extends StatelessWidget {
  const _LiveSyncCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SectionCard(
      title: 'بررسی آنلاین سامانه',
      subtitle:
          'پیش‌فرض خاموش است. یادآورها از اطلاعات ذخیره‌شده روی گوشی استفاده می‌کنند '
          'و برای هر اعلان وارد سامانه نمی‌شوند.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.cloud_off_outlined,
                  size: 20, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'خاموش (پیش‌فرض)',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'با روشن کردن این گزینه، پیش از هر اعلان وضعیت از سامانه خوانده می‌شود. '
            'این کار هر بار یک ورود به سامانه لازم دارد.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
