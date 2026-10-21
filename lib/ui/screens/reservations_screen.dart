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
class ReservationsScreen extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final accounts = state.accounts;

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

        final accountId = state.activeHuntAccount ?? accounts.first.id;
        final rows = buildMealRows(
          menus: menus,
          held: state.mealsFor(accountId),
          clock: clock,
        );

        return Scaffold(
          appBar: AppBar(
            title: const Text('رزروها'),
            actions: [
              if (onRefresh != null)
                IconButton(
                  onPressed: onRefresh,
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
                  onChanged: state.selectHuntAccount,
                ),
              Expanded(
                child: ReservationsTable(
                  rows: rows,
                  busy: busy,
                  busyKey: busyKey,
                  onBook: (date, slot) => onBook?.call(date, slot),
                  onCancel: (date, slot) => onCancel?.call(date, slot),
                ),
              ),
            ],
          ),
        );
      },
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
