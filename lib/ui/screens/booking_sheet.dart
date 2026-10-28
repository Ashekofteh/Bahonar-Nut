/// The booking sheet: choosing the dish and the hall for one meal.
///
/// ## Why a sheet and not a screen
///
/// Booking is a **commitment**. The cutoff is 20:00 two days before the
/// meal, and after it the meal cannot be given back (F14) — so the decision
/// needs the dish, the price, the hall and the date all visible at once,
/// and it needs to be *finished* in one place.
///
/// A bottom sheet over the table keeps the student in the week they were
/// reading. A full screen would hide the table and make the student
/// remember where they were.
///
/// ## The one-meal rule
///
/// The portal does **not** enforce one meal per slot per day (F22): the
/// basket offers a meal the account already holds, and the server accepts a
/// second booking without complaint. So the rule is checked by the app before
/// the request goes out — and the app is the only thing standing between the
/// student and a double booking they cannot undo.
library;

import 'package:flutter/material.dart';

import '../../core/hunt_notify.dart' show mealSlotPersian;
import '../../core/models.dart';
import '../../core/persian.dart';
import '../widgets.dart';

/// The sheet that books one meal.
class BookingSheet extends StatefulWidget {
  const BookingSheet({
    super.key,
    required this.menu,
    required this.onBook,
    this.currentBalanceRial,
    this.onTopUp,
    this.busy = false,
    this.error,
  });

  /// The menu for the meal being booked.
  final MealMenu menu;

  /// Books the chosen offering. Returns the message to show, or null.
  final Future<String?> Function(MealOffering offering) onBook;

  /// The account's current balance in Rial, for deficit detection.
  final int? currentBalanceRial;

  /// Directs the student to increase balance when deficit is detected.
  final void Function(int deficitRial)? onTopUp;

  /// Whether a booking is in flight.
  final bool busy;

  /// Why the last attempt failed.
  final String? error;

  /// Shows the sheet.
  static Future<void> show(
    BuildContext context, {
    required MealMenu menu,
    required Future<String?> Function(MealOffering offering) onBook,
    int? currentBalanceRial,
    void Function(int deficitRial)? onTopUp,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (_) => BookingSheet(
        menu: menu,
        onBook: onBook,
        currentBalanceRial: currentBalanceRial,
        onTopUp: onTopUp,
      ),
    );
  }

  @override
  State<BookingSheet> createState() => _BookingSheetState();
}

class _BookingSheetState extends State<BookingSheet> {
  OptionId? _dish;
  HallId? _hall;
  bool _busy = false;
  String? _error;

  int? get _deficitRial {
    if (widget.currentBalanceRial == null || _dish == null) return null;
    final dish = widget.menu.dishes.firstWhere(
      (d) => d.id == _dish,
      orElse: () => widget.menu.dishes.first,
    );
    final deficit = dish.priceRial - widget.currentBalanceRial!;
    return deficit > 0 ? deficit : null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final menu = widget.menu;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.8,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${mealSlotPersian(menu.slot)} — ${formatPersianDate(menu.date)}',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 2),
                Text(
                  'غذای مورد نظر را انتخاب کنید.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),

                if (_error != null) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: theme.colorScheme.errorContainer,
                    ),
                    child: Text(
                      _error!,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                _Dishes(
                  menu: menu,
                  selected: _dish,
                  onChanged: (id) => setState(() => _dish = id),
                ),

                if (_deficitRial != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.account_balance_wallet_outlined,
                            size: 20, color: theme.colorScheme.error),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'کسری موجودی: ${formatTomanPersian(_deficitRial!)}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onErrorContainer,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (widget.onTopUp != null)
                          TextButton(
                            onPressed: () {
                              final deficit = _deficitRial!;
                              Navigator.of(context).pop();
                              widget.onTopUp!(deficit);
                            },
                            child: const Text('افزایش موجودی'),
                          ),
                      ],
                    ),
                  ),
                ],

                if (menu.halls.length > 1) ...[
                  const SizedBox(height: 20),
                  _Halls(
                    halls: menu.halls,
                    selected: _hall,
                    onChanged: (id) => setState(() => _hall = id),
                  ),
                ],

                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _dish == null || _busy ? null : _book,
                    icon: Icon(_busy ? Icons.hourglass_empty : Icons.check),
                    label: Text(_busy ? 'در حال ثبت' : 'ثبت رزرو'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Books the chosen dish and hall.
  Future<void> _book() async {
    final menu = widget.menu;
    final dishId = _dish;
    if (dishId == null) return;

    final deficit = _deficitRial;
    if (deficit != null && widget.onTopUp != null) {
      final goToTopUp = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('کمبود موجودی حساب'),
          content: Text(
            'موجودی حساب برای رزرو این غذا کافی نیست.\n'
            'کسری موجودی: ${formatTomanPersian(deficit)}\n\n'
            'آیا مایلید برای افزایش اعتبار به صفحه پرداخت هدایت شوید؟',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('انصراف'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('افزایش موجودی'),
            ),
          ],
        ),
      );

      if (goToTopUp == true && mounted) {
        Navigator.of(context).pop();
        widget.onTopUp!(deficit);
        return;
      }
    }

    final dish = menu.dishes.firstWhere(
      (d) => d.id == dishId,
      orElse: () => menu.dishes.first,
    );

    // The hall is a choice, not a property of the dish: the portal serves
    // every hall on the same menu. An unchosen hall means the first one the
    // portal lists.
    final hall = _hall == null
        ? menu.halls.first
        : menu.halls.firstWhere(
            (h) => h.id == _hall,
            orElse: () => menu.halls.first,
          );

    setState(() {
      _busy = true;
      _error = null;
    });

    final message = await widget.onBook(MealOffering(
      date: menu.date,
      slot: menu.slot,
      hall: hall,
      option: dish,
      reservable: menu.reservable,
    ));

    if (!mounted) return;

    if (message == null) {
      Navigator.of(context).pop();
      return;
    }

    setState(() {
      _busy = false;
      _error = message;
    });
  }
}

/// The dishes on offer.
class _Dishes extends StatelessWidget {
  const _Dishes({
    required this.menu,
    required this.selected,
    required this.onChanged,
  });

  final MealMenu menu;
  final OptionId? selected;
  final void Function(OptionId) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('غذا', style: theme.textTheme.bodyMedium),
        const SizedBox(height: 8),
        RadioGroup<String>(
          groupValue: selected,
          onChanged: (v) {
            if (v == null) return;
            onChanged(v);
          },
          child: Column(
            children: [
              for (final dish in menu.dishes)
                RadioListTile<String>(
                  value: dish.id,
                  title: Text(dish.name),
                  subtitle: MoneyText(
                    dish.priceRial,
                    style: theme.textTheme.bodySmall,
                    colour: theme.colorScheme.onSurfaceVariant,
                  ),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The halls the meal is served in.
class _Halls extends StatelessWidget {
  const _Halls({
    required this.halls,
    required this.selected,
    required this.onChanged,
  });

  final List<Hall> halls;
  final HallId? selected;
  final void Function(HallId) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'سلف',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 2),
        Text(
          'سلفی که می‌خواهید غذا را از آن بگیرید.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        RadioGroup<String>(
          groupValue: selected,
          onChanged: (v) {
            if (v == null) return;
            onChanged(v);
          },
          child: Column(
            children: [
              for (final hall in halls)
                RadioListTile<String>(
                  value: hall.id,
                  title: Text(hall.name),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                ),
            ],
          ),
        ),
      ],
    );
  }
}
