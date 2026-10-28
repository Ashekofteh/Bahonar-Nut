import 'package:flutter/material.dart';

import '../../core/account.dart';
import '../../core/models.dart';
import '../../core/time.dart';
import '../app_state.dart';
import '../reservation_table_model.dart';
import '../widgets.dart';
import 'reservations_table.dart';

/// The reservations screen: the student's week, in one table.
///
/// ## What it shows
///
/// One grid, one row per (date, meal) across the days that can still be
/// acted on. Every row states one thing plainly — what is the state of this
/// meal — and offers exactly one action:
///
///   * **held** — a weekly reservation, with a cancel button;
///   * **bought** — a Food Basket purchase, which is irreversible (F16), so
///     the row says so and offers nothing;
///   * **bookable** — served, still open, with a book button;
///   * **locked** — served, but the cutoff has passed, so nothing is offered.
///
/// ## The account picker
///
/// The student may hold several accounts, and the table is about **one**
/// account's meals. So the screen names the account it is showing, and the
/// student can switch. The picker is a row of chips, because the choice is
/// between a handful of names and it must be visible at a glance.
class ReservationsScreen extends StatefulWidget {
  const ReservationsScreen({
    super.key,
    required this.state,
    this.onBook,
    this.onCancel,
    this.onRefresh,
    this.menus = const [],
    this.clock,
    this.busy = false,
    this.busyKey,
  });

  final AppState state;

  /// Opens the booking sheet for a (date, slot).
  final void Function(DateTime date, MealSlot slot)? onBook;

  /// Cancels a held meal.
  final void Function(DateTime date, MealSlot slot)? onCancel;

  /// Re-reads the portal.
  final VoidCallback? onRefresh;

  /// The portal's menu for the days that can still be booked.
  final List<MealMenu> menus;

  /// The server's clock, for the cutoff.
  final ServerClock? clock;

  /// Whether an action is in flight.
  final bool busy;

  /// The (date, slot) the in-flight action belongs to.
  final String? busyKey;

  @override
  State<ReservationsScreen> createState() => _ReservationsScreenState();
}

class _ReservationsScreenState extends State<ReservationsScreen> {
  /// Offset in weeks from the current week (0 = current week, 1 = next week, -1 = last week).
  /// Navigation is unconstrained: tapping next week or previous week advances or rewinds freely.
  int _weekOffset = 0;

  DateTime _currentSaturday() {
    final now = widget.clock != null && widget.clock!.isSynced
        ? widget.clock!.portalTodayUtc
        : DateTime.now().toUtc();
    return weekStartSaturday(now);
  }

  DateTime _selectedSaturday() {
    final currentSat = _currentSaturday();
    return currentSat.add(Duration(days: _weekOffset * 7));
  }

  void _previousWeek() {
    setState(() {
      _weekOffset--;
    });
  }

  void _nextWeek() {
    setState(() {
      _weekOffset++;
    });
  }

  void _resetToCurrentWeek() {
    setState(() {
      _weekOffset = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final accounts = widget.state.accounts;

        if (accounts.isEmpty) {
          return Scaffold(
            appBar: AppBar(title: const Text('رزروها')),
            body: const EmptyState(
              icon: Icons.people_outline,
              title: 'هنوز حسابی اضافه نشده است',
              message: 'برای دیدن رزروها، ابتدا یک حساب اضافه کنید.',
            ),
          );
        }

        final accountId = widget.state.activeHuntAccount ?? accounts.first.id;
        final allRows = buildMealRows(
          menus: widget.menus,
          held: widget.state.mealsFor(accountId),
          clock: widget.clock,
        );

        final selectedSat = _selectedSaturday();
        final weekRows = filterRowsForWeek(allRows, selectedSat);

        return Scaffold(
          appBar: AppBar(
            title: const Text('رزروها'),
            actions: [
              if (widget.onRefresh != null)
                IconButton(
                  onPressed: widget.onRefresh,
                  icon: const Icon(Icons.refresh),
                  tooltip: 'به‌روزرسانی از سامانه',
                ),
            ],
          ),
          body: Column(
            children: [
              if (accounts.length > 1)
                _AccountPicker(
                  accounts: accounts,
                  activeId: accountId,
                  onChanged: widget.state.selectHuntAccount,
                ),
              _WeekNavigator(
                weekOffset: _weekOffset,
                saturday: selectedSat,
                onPrevious: _previousWeek,
                onNext: _nextWeek,
                onReset: _resetToCurrentWeek,
              ),
              Expanded(
                child: ReservationsTable(
                  rows: weekRows,
                  busy: widget.busy,
                  busyKey: widget.busyKey,
                  emptyTitle: _weekOffset < 0
                      ? 'هیچ رزروی در این هفته ثبت نشده است'
                      : (_weekOffset > 1
                          ? 'برنامه غذایی این هفته هنوز ارائه نشده است'
                          : 'هنوز وعده‌ای برای نمایش نیست'),
                  emptyMessage: _weekOffset < 0
                      ? 'در این هفته هیچ وعده رزروشده یا خریداری‌شده‌ای برای این حساب وجود ندارد.'
                      : (_weekOffset > 1
                          ? 'سامانه دانشگاه معمولاً برنامه غذایی را حداکثر تا یک هفته قبل ارائه می‌دهد.'
                          : 'پس از دریافت برنامه غذایی یا رزرو، وعده‌ها اینجا نمایش داده می‌شوند.'),
                  onBook: (date, slot) => widget.onBook?.call(date, slot),
                  onCancel: (date, slot) => widget.onCancel?.call(date, slot),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Navigation bar allowing unconstrained forward/backward week paging
/// while showing the Persian week label and Jalali date range.
class _WeekNavigator extends StatelessWidget {
  const _WeekNavigator({
    required this.weekOffset,
    required this.saturday,
    required this.onPrevious,
    required this.onNext,
    required this.onReset,
  });

  final int weekOffset;
  final DateTime saturday;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final weekTitle = formatWeekTitle(weekOffset);
    final weekRange = formatWeekRange(saturday);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          // In Persian RTL: Next Week (future) progresses towards start/left.
          // Arrow forward is Icons.arrow_back in RTL, or chevron.
          IconButton(
            icon: const Icon(Icons.chevron_right),
            tooltip: 'هفته قبل',
            onPressed: onPrevious,
          ),
          Expanded(
            child: InkWell(
              onTap: weekOffset != 0 ? onReset : null,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          weekTitle,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: weekOffset == 0
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurface,
                          ),
                        ),
                        if (weekOffset != 0) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              'بازگشت به امروز',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onPrimaryContainer,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      weekRange,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_left),
            tooltip: 'هفته بعد',
            onPressed: onNext,
          ),
        ],
      ),
    );
  }
}


/// The row of chips that picks the account the table shows.
class _AccountPicker extends StatelessWidget {
  const _AccountPicker({
    required this.accounts,
    required this.activeId,
    required this.onChanged,
  });

  final List<SavedAccount> accounts;
  final AccountId activeId;
  final void Function(AccountId) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      color: theme.colorScheme.surface,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'حساب',
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final account in accounts)
                ChoiceChip(
                  label: Text(account.resolvedName),
                  selected: account.id == activeId,
                  onSelected: (_) => onChanged(account.id),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
