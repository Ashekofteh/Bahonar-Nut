import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/persian.dart';
import '../../core/spend_summary.dart';
import '../app_state.dart';
import '../widgets.dart';

/// The finance dashboard: what the meals cost, broken down.
///
/// Two things make this screen honest:
///
///   * **The filters are multi-select on both dimensions.** Accounts and meal
///     slots can be combined freely, and an empty selection means "everything"
///     rather than "nothing".
///   * **The figure is meals reserved, not money spent.** The ledger records
///     reservations, not whether the meal was eaten, and an uneaten meal still
///     incurs the portal's penalty. The label says so.
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final summary = state.spendSummary;

        return Scaffold(
          appBar: AppBar(
            title: const Text('خرج غذا'),
            actions: [
              if (!state.spendFilter.isUnfiltered)
                TextButton(
                  onPressed: state.clearSpendFilter,
                  child: const Text('پاک کردن فیلتر'),
                ),
            ],
          ),
          body: state.transactions.isEmpty
              ? const EmptyState(
                  icon: Icons.pie_chart_outline,
                  title: 'هنوز تراکنشی ثبت نشده',
                  message: 'پس از اولین رزرو یا خرید، هزینه‌ها اینجا نمایش داده می‌شوند.',
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                  children: [
                    _TotalsCard(summary: summary),
                    const SizedBox(height: 12),
                    _FilterCard(state: state),
                    const SizedBox(height: 12),
                    _BreakdownCard(summary: summary),
                    if (summary.entries.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      _EntriesCard(summary: summary),
                    ],
                  ],
                ),
        );
      },
    );
  }
}

/// The headline figures.
class _TotalsCard extends StatelessWidget {
  const _TotalsCard({required this.summary});

  final SpendSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SectionCard(
      title: 'مجموع',
      subtitle: 'هزینه وعده‌های رزروشده (تومان)',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              MoneyText(
                summary.totalRial,
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.secondary,
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  'برای ${toPersianDigits(summary.totalMeals)} وعده',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 16,
            runSpacing: 6,
            children: [
              _MiniStat(
                label: 'میانگین هر وعده',
                child: MoneyText(summary.averageMealRial,
                    style: theme.textTheme.titleSmall),
              ),
              if (summary.excludedWithdrawn > 0)
                _MiniStat(
                  label: 'وعده آزادشده (کسر شده)',
                  child: Text(
                    toPersianDigits(summary.excludedWithdrawn),
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        child,
      ],
    );
  }
}

/// The multi-select filters.
class _FilterCard extends StatelessWidget {
  const _FilterCard({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accounts = state.accounts;
    final filter = state.spendFilter;

    return SectionCard(
      title: 'فیلتر',
      subtitle: 'چند حساب و چند وعده را هم‌زمان انتخاب کنید',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'حساب‌ها',
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          if (accounts.isEmpty)
            Text(
              'حسابی ذخیره نشده است.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final account in accounts)
                  FilterChip(
                    label: Text(account.resolvedName),
                    selected: filter.accountIds.contains(account.id),
                    onSelected: (_) =>
                        state.toggleSpendAccount(account.id),
                  ),
              ],
            ),
          const SizedBox(height: 16),
          Text(
            'وعده‌ها',
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final slot in MealSlot.values)
                FilterChip(
                  label: Text(mealSlotName(slot)),
                  selected: filter.slots.contains(slot),
                  onSelected: (_) => state.toggleSpendSlot(slot),
                ),
            ],
          ),
          if (filter.isUnfiltered) ...[
            const SizedBox(height: 12),
            Text(
              'بدون فیلتر — همه حساب‌ها و همه وعده‌ها نمایش داده می‌شوند.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The per-slot breakdown with a bar chart.
class _BreakdownCard extends StatelessWidget {
  const _BreakdownCard({required this.summary});

  final SpendSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final slots = MealSlot.values
        .where((s) => (summary.bySlot.totals[s] ?? 0) > 0)
        .toList();

    if (slots.isEmpty) {
      return SectionCard(
        title: 'تفکیک بر اساس وعده',
        child: Text(
          'داده‌ای برای نمایش نیست.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    final maxTotal = slots
        .map((s) => summary.bySlot.totals[s] ?? 0)
        .reduce((a, b) => a > b ? a : b);

    return SectionCard(
      title: 'تفکیک بر اساس وعده',
      subtitle: 'سهم هر وعده از مجموع',
      child: Column(
        children: [
          for (final slot in slots) ...[
            _BarRow(
              label: mealSlotName(slot),
              amountRial: summary.bySlot.totals[slot] ?? 0,
              fraction: maxTotal == 0
                  ? 0
                  : (summary.bySlot.totals[slot] ?? 0) / maxTotal,
              count: summary.bySlot.counts[slot] ?? 0,
            ),
            if (slot != slots.last) const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }
}

/// One bar of the breakdown.
class _BarRow extends StatelessWidget {
  const _BarRow({
    required this.label,
    required this.amountRial,
    required this.fraction,
    required this.count,
  });

  final String label;
  final int amountRial;
  final double fraction;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label, style: theme.textTheme.bodyMedium),
            ),
            Text(
              '${toPersianDigits(count)} وعده',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 10),
            MoneyText(amountRial, style: theme.textTheme.titleSmall),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: fraction,
            minHeight: 8,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
            valueColor: AlwaysStoppedAnimation(theme.colorScheme.secondary),
          ),
        ),
      ],
    );
  }
}

/// The per-meal list.
class _EntriesCard extends StatelessWidget {
  const _EntriesCard({required this.summary});

  final SpendSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SectionCard(
      title: 'وعده‌ها',
      subtitle: '${toPersianDigits(summary.entries.length)} مورد',
      child: Column(
        children: [
          for (final entry in summary.entries) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.foodName,
                        style: theme.textTheme.bodyMedium,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '${formatPersianDate(entry.date)} • ${mealSlotName(entry.slot)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                MoneyText(entry.amountRial, style: theme.textTheme.titleSmall),
              ],
            ),
            if (entry != summary.entries.last) const Divider(height: 20),
          ],
        ],
      ),
    );
  }
}

/// The Persian name of a meal slot.
String mealSlotName(MealSlot slot) => switch (slot) {
      MealSlot.breakfast => 'صبحانه',
      MealSlot.lunch => 'ناهار',
      MealSlot.dinner => 'شام',
    };
