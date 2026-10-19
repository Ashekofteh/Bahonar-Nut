import 'package:flutter/material.dart';

import '../../core/local_meal_store.dart';
import '../../core/models.dart';
import '../../core/persian.dart';
import '../app_state.dart';
import '../widgets.dart';
import 'dashboard_screen.dart' show mealSlotName;

/// The reservations screen: what the student is holding, and for which day.
///
/// Reads the **local store**, so it works offline and needs no portal login —
/// which is the whole point of the offline-first design. The local store is
/// updated whenever the app completes a booking, a basket purchase or a
/// cancellation, and refreshed from the portal when the live check is enabled.
class ReservationsScreen extends StatelessWidget {
  const ReservationsScreen({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        // Group every held meal by date, newest first.
        final byDate = <DateTime, List<StoredMeal>>{};
        for (final account in state.accounts) {
          for (final meal in state.mealsFor(account.id)) {
            byDate.putIfAbsent(meal.date, () => []).add(meal);
          }
        }

        final dates = byDate.keys.toList()
          ..sort((a, b) => b.compareTo(a));

        return Scaffold(
          appBar: AppBar(title: const Text('رزروها')),
          body: dates.isEmpty
              ? const EmptyState(
                  icon: Icons.restaurant_menu_outlined,
                  title: 'هنوز رزروی برای نمایش نیست',
                  message:
                      'پس از رزرو یا خرید، وعده‌های شما اینجا فهرست می‌شوند.',
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                  children: [
                    for (final date in dates) ...[
                      _DayGroup(
                        date: date,
                        meals: byDate[date]!,
                        accountNames: {
                          for (final account in state.accounts)
                            account.id: account.resolvedName,
                        },
                      ),
                      const SizedBox(height: 12),
                    ],
                  ],
                ),
        );
      },
    );
  }
}

/// A day's held meals.
class _DayGroup extends StatelessWidget {
  const _DayGroup({
    required this.date,
    required this.meals,
    required this.accountNames,
  });

  final DateTime date;
  final List<StoredMeal> meals;
  final Map<String, String> accountNames;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SectionCard(
      title: formatPersianDate(date),
      subtitle: '${toPersianDigits(meals.length)} وعده',
      child: Column(
        children: [
          for (final meal in meals) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  _iconFor(meal.slot),
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        meal.dishName ?? mealSlotName(meal.slot),
                        style: theme.textTheme.bodyMedium,
                      ),
                      Text(
                        [
                          if (meal.hallName != null) meal.hallName!,
                          accountNames[meal.accountId],
                        ].whereType<String>().join(' • '),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (meal.priceRial != null)
                  MoneyText(meal.priceRial!, style: theme.textTheme.titleSmall),
              ],
            ),
            if (meal != meals.last) const Divider(height: 20),
          ],
        ],
      ),
    );
  }

  static IconData _iconFor(MealSlot slot) => switch (slot) {
        MealSlot.breakfast => Icons.wb_twilight,
        MealSlot.lunch => Icons.lunch_dining_outlined,
        MealSlot.dinner => Icons.dark_mode_outlined,
      };
}
