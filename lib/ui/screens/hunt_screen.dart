/// The hunt screen: "تعیین بازه زمانی و وعده غذایی" — the portal's own phrase
/// for this feature, used here so the app speaks the same language as the
/// thing it automates.
///
/// ## Why a wizard
///
/// Each step depends on the one before it. The date and the meal decide which
/// dishes the portal is serving; the dishes and the halls decide what the
/// hunt buys; the rate decides what the hunt costs in requests. Showing them
/// as one flat form would mean the user picks a dish before knowing whether
/// the portal serves it that day.
///
/// ## The number that matters
///
/// The projected request count is the figure the user is actually trading
/// against, so it sits next to the slider and moves as the slider moves. A
/// label saying "fast" is not information; a count that changes is.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/hunt_config.dart';
import '../../core/models.dart';
import '../../core/persian.dart';
import '../../core/time.dart';
import '../theme.dart';
import '../widgets.dart';

/// A dish the portal offers, as the hunt screen sees it.
///
/// Carries the hall it is offered in, because the buy page lists the dishes
/// on offer *and* the halls the row is served in, and the user picks both.
class HuntDishOption {
  const HuntDishOption({
    required this.optionId,
    required this.name,
    required this.priceRial,
    required this.halls,
  });

  final String optionId;
  final String name;
  final int priceRial;

  /// The halls the market offers this dish in.
  final List<Hall> halls;
}

/// The screen's view of the hunt, so the widget can be driven from a test.
class HuntScreen extends StatefulWidget {
  const HuntScreen({
    super.key,
    required this.dishes,
    required this.halls,
    required this.config,
    required this.onConfigChanged,
    this.preflightSummary,
    this.preflightRefusal,
    this.onStart,
    this.onStop,
    this.isRunning = false,
  });

  /// The dishes the portal offers for the chosen date and slot.
  final List<HuntDishOption> dishes;

  /// The halls the portal named for this account.
  final List<Hall> halls;

  /// The configuration being edited.
  final HuntConfig config;

  /// Called whenever the user changes the configuration.
  final void Function(HuntConfig) onConfigChanged;

  /// The pre-flight verdict, when the hunt is ready to start.
  final String? preflightSummary;

  /// Why the hunt was refused, when it was.
  final String? preflightRefusal;

  /// Starts the hunt. Null when the screen cannot start one.
  final VoidCallback? onStart;

  /// Stops a running hunt.
  final VoidCallback? onStop;

  /// Whether a hunt is currently running.
  final bool isRunning;

  @override
  State<HuntScreen> createState() => _HuntScreenState();
}

class _HuntScreenState extends State<HuntScreen> {
  @override
  Widget build(BuildContext context) {
    final config = widget.config;

    return Scaffold(
      appBar: AppBar(title: const Text('شکار')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          _WindowCard(config: config, onChanged: widget.onConfigChanged),
          const SizedBox(height: 12),
          _DishesCard(
            config: config,
            dishes: widget.dishes,
            onChanged: widget.onConfigChanged,
          ),
          const SizedBox(height: 12),
          _HallsCard(
            config: config,
            halls: widget.halls,
            onChanged: widget.onConfigChanged,
          ),
          const SizedBox(height: 12),
          _RateCard(config: config, onChanged: widget.onConfigChanged),
          const SizedBox(height: 12),
          _PreflightCard(
            config: config,
            summary: widget.preflightSummary,
            refusal: widget.preflightRefusal,
            isRunning: widget.isRunning,
            onStart: widget.onStart,
            onStop: widget.onStop,
          ),
        ],
      ),
    );
  }
}

/// The hunt's own window, and the peak window it implies.
class _WindowCard extends StatelessWidget {
  const _WindowCard({required this.config, required this.onChanged});

  final HuntConfig config;
  final void Function(HuntConfig) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final peak = config.peakWindow;

    return SectionCard(
      title: 'بازه زمانی',
      subtitle: 'شکار فقط در این بازه اجرا می‌شود؛ بیرون از آن هیچ درخواستی '
          'فرستاده نمی‌شود.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TimeRow(
            label: 'شروع',
            value: config.windowStart,
            onChanged: (t) => onChanged(config.copyWith(windowStart: t)),
          ),
          const SizedBox(height: 8),
          _TimeRow(
            label: 'پایان',
            value: config.windowEnd,
            onChanged: (t) => onChanged(config.copyWith(windowEnd: t)),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.5),
            ),
            child: Row(
              children: [
                Icon(Icons.bolt,
                    size: 20, color: theme.colorScheme.secondary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'بازه اوج ${mealSlotPersian(config.targetSlot)}: '
                    '${formatClockTimePersian(peak.start.hour, peak.start.minute)}'
                    ' تا '
                    '${formatClockTimePersian(peak.end.hour, peak.end.minute)}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.secondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One editable time.
class _TimeRow extends StatelessWidget {
  const _TimeRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final ClockTime value;
  final void Function(ClockTime) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: () async {
        final picked = await showTimePicker(
          context: context,
          initialTime: TimeOfDay(hour: value.hour, minute: value.minute),
          helpText: label,
          builder: (context, child) => Directionality(
            textDirection: TextDirection.rtl,
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
              child: child!,
            ),
          ),
        );
        if (picked == null) return;
        onChanged(ClockTime(picked.hour, picked.minute));
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Row(
          children: [
            Icon(Icons.schedule,
                size: 20, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Text(label, style: theme.textTheme.bodyMedium),
            const Spacer(),
            Text(
              formatClockTimePersian(value.hour, value.minute),
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The dishes, in priority order.
class _DishesCard extends StatelessWidget {
  const _DishesCard({
    required this.config,
    required this.dishes,
    required this.onChanged,
  });

  final HuntConfig config;
  final List<HuntDishOption> dishes;
  final void Function(HuntConfig) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SectionCard(
      title: 'غذاها',
      subtitle: 'اولویت اول خریداری می‌شود؛ اگر موجود نبود، دومی خریداری '
          'می‌شود. انتخاب دومی اختیاری است.',
      child: dishes.isEmpty
          ? Text(
              'برای این تاریخ و وعده غذایی در سامانه موجود نیست.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          : Column(
              children: [
                for (final dish in dishes)
                  _DishTile(
                    dish: dish,
                    position: _positionOf(dish),
                    onToggle: () => _toggle(dish),
                  ),
              ],
            ),
    );
  }

  /// The 1-based priority position of a dish, or null when it is not chosen.
  int? _positionOf(HuntDishOption dish) {
    final key = normalizeDishName(dish.name);
    for (var i = 0; i < config.dishPriority.length; i++) {
      if (config.dishPriority[i].dishKey == key) return i + 1;
    }
    return null;
  }

  /// Adds a dish to the end of the list, or removes it.
  void _toggle(HuntDishOption dish) {
    final key = normalizeDishName(dish.name);
    final existing = config.dishPriority.indexWhere(
      (d) => d.dishKey == key,
    );

    if (existing >= 0) {
      final next = List<HuntDish>.from(config.dishPriority)..removeAt(existing);
      onChanged(config.copyWith(dishPriority: next));
      return;
    }

    // The list is capped at two: "the first choice, then the second". A third
    // would be a rule the user cannot hold in their head, and the pre-flight
    // credit check would then demand the sum of three meals.
    if (config.dishPriority.length >= 2) return;

    onChanged(config.copyWith(
      dishPriority: [
        ...config.dishPriority,
        HuntDish(
          optionId: dish.optionId,
          name: dish.name,
          priceRial: dish.priceRial,
        ),
      ],
    ));
  }
}

/// One dish, with its priority mark and its price.
class _DishTile extends StatelessWidget {
  const _DishTile({
    required this.dish,
    required this.position,
    required this.onToggle,
  });

  final HuntDishOption dish;
  final int? position;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = position != null;

    return CheckboxListTile(
      value: selected,
      onChanged: (_) => onToggle(),
      title: Text(dish.name),
      subtitle: MoneyText(
        dish.priceRial,
        style: theme.textTheme.bodySmall,
        colour: theme.colorScheme.onSurfaceVariant,
      ),
      secondary: selected
          ? CircleAvatar(
              radius: 14,
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Text(
                toPersianDigits(position!),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.w700,
                ),
              ),
            )
          : null,
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
    );
  }
}

/// The halls, in priority order.
class _HallsCard extends StatelessWidget {
  const _HallsCard({
    required this.config,
    required this.halls,
    required this.onChanged,
  });

  final HuntConfig config;
  final List<Hall> halls;
  final void Function(HuntConfig) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SectionCard(
      title: 'سلف‌ها',
      subtitle: 'خالی گذاشتن یعنی «هر سلفی که سامانه پیشنهاد دهد».',
      child: halls.isEmpty
          ? Text(
              'سلف‌های این حساب هنوز خوانده نشده است.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          : Column(
              children: [
                for (final hall in halls)
                  _HallTile(
                    hall: hall,
                    position: _positionOf(hall),
                    onToggle: () => _toggle(hall),
                  ),
              ],
            ),
    );
  }

  int? _positionOf(Hall hall) {
    for (var i = 0; i < config.hallPriority.length; i++) {
      if (config.hallPriority[i].id == hall.id) return i + 1;
    }
    return null;
  }

  void _toggle(Hall hall) {
    final existing =
        config.hallPriority.indexWhere((h) => h.id == hall.id);

    if (existing >= 0) {
      final next = List<HuntHall>.from(config.hallPriority)..removeAt(existing);
      onChanged(config.copyWith(hallPriority: next));
      return;
    }

    if (config.hallPriority.length >= 2) return;

    onChanged(config.copyWith(
      hallPriority: [...config.hallPriority, HuntHall(id: hall.id, name: hall.name)],
    ));
  }
}

/// One hall, with its priority mark.
class _HallTile extends StatelessWidget {
  const _HallTile({
    required this.hall,
    required this.position,
    required this.onToggle,
  });

  final Hall hall;
  final int? position;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = position != null;

    return CheckboxListTile(
      value: selected,
      onChanged: (_) => onToggle(),
      title: Text(hall.name),
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      secondary: selected
          ? CircleAvatar(
              radius: 14,
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Text(
                toPersianDigits(position!),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.w700,
                ),
              ),
            )
          : null,
    );
  }
}

/// The rate: a slider per interval, and the cost of the rate.
class _RateCard extends StatelessWidget {
  const _RateCard({required this.config, required this.onChanged});

  final HuntConfig config;
  final void Function(HuntConfig) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rate = config.rate;
    final projected = config.projectedRequests();

    return SectionCard(
      title: 'سرعت بررسی',
      subtitle: 'هرچه فاصله کمتر باشد، شکار سریع‌تر است و درخواست بیشتری '
          'فرستاده می‌شود.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _IntervalSlider(
            label: 'در بازه اوج',
            value: rate.peakInterval,
            min: HuntBounds.minPeakInterval,
            max: HuntBounds.maxPeakInterval,
            accent: _accentFor(rate.peakInterval),
            onChanged: (d) => onChanged(
              config.copyWith(rate: rate.copyWith(peakInterval: d)),
            ),
          ),
          const SizedBox(height: 16),
          _IntervalSlider(
            label: 'بیرون از بازه اوج',
            value: rate.offPeakInterval,
            min: HuntBounds.minOffPeakInterval,
            max: HuntBounds.maxOffPeakInterval,
            accent: _accentFor(rate.offPeakInterval),
            onChanged: (d) => onChanged(
              config.copyWith(rate: rate.copyWith(offPeakInterval: d)),
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: theme.colorScheme.surfaceContainerHighest,
            ),
            child: Row(
              children: [
                Icon(Icons.cloud_upload_outlined,
                    size: 20, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'حدود ${toPersianDigits(projected)} درخواست در این بازه',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The band colour for an interval: green when safe, amber near the risk
  /// threshold, red at the aggressive extreme.
  static Color _accentFor(Duration interval) {
    if (interval < HuntBounds.riskAcknowledgementThreshold) {
      return AppColors.released;
    }
    if (interval < const Duration(seconds: 20)) return AppColors.closing;
    return AppColors.held;
  }
}

/// A logarithmic slider over an interval range.
///
/// Logarithmic because the useful range spans 2 to 60 seconds, and a linear
/// slider spends most of its travel on the slow end, where nothing interesting
/// happens.
class _IntervalSlider extends StatelessWidget {
  const _IntervalSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.accent,
    required this.onChanged,
  });

  final String label;
  final Duration value;
  final Duration min;
  final Duration max;
  final Color accent;
  final void Function(Duration) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final clamped = value < min ? min : (value > max ? max : value);
    final position = _positionOf(clamped);
    final steps = _steps();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label, style: theme.textTheme.bodyMedium),
            const Spacer(),
            Text(
              _formatInterval(clamped),
              style: theme.textTheme.titleMedium?.copyWith(
                color: accent,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        Slider(
          value: position,
          min: 0,
          max: 1,
          divisions: steps,
          activeColor: accent,
          label: _formatInterval(clamped),
          onChanged: (p) => onChanged(_durationAt(p)),
        ),
      ],
    );
  }

  /// The number of discrete stops.
  ///
  /// One per second in the fast range, one per five seconds in the slow one —
  /// the slider is logarithmic, so the stops are too.
  int _steps() {
    final span = max.inSeconds - min.inSeconds;
    if (span <= 60) return span;
    return (span / 5).ceil();
  }

  /// The slider position for a duration, on a log scale.
  double _positionOf(Duration d) {
    final lo = _log(min.inSeconds.toDouble());
    final hi = _log(max.inSeconds.toDouble());
    final v = _log(d.inSeconds.toDouble());
    if (hi <= lo) return 0;
    return ((v - lo) / (hi - lo)).clamp(0.0, 1.0);
  }

  /// The duration at a slider position.
  Duration _durationAt(double position) {
    final lo = _log(min.inSeconds.toDouble());
    final hi = _log(max.inSeconds.toDouble());
    final seconds = math.pow(10, lo + (hi - lo) * position).toDouble();
    return Duration(milliseconds: (seconds * 1000).round());
  }

  /// The base-10 logarithm, so the slider's travel matches its scale.
  static double _log(double x) => math.log(x) / math.ln10;

  /// An interval in Persian, e.g. «۱۰ ثانیه».
  static String _formatInterval(Duration d) {
    if (d.inSeconds < 60) {
      return '${toPersianDigits(d.inSeconds)} ثانیه';
    }
    if (d.inSeconds < 3600) {
      final minutes = d.inSeconds ~/ 60;
      final seconds = d.inSeconds % 60;
      if (seconds == 0) return '${toPersianDigits(minutes)} دقیقه';
      return '${toPersianDigits(minutes)} دقیقه و ${toPersianDigits(seconds)} ثانیه';
    }
    return '${toPersianDigits(d.inMinutes)} دقیقه';
  }
}

/// The pre-flight result, and the button that starts the hunt.
class _PreflightCard extends StatelessWidget {
  const _PreflightCard({
    required this.config,
    required this.summary,
    required this.refusal,
    required this.isRunning,
    required this.onStart,
    required this.onStop,
  });

  final HuntConfig config;
  final String? summary;
  final String? refusal;
  final bool isRunning;
  final VoidCallback? onStart;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SectionCard(
      title: 'آمادگی شکار',
      subtitle: isRunning
          ? 'شکار در حال اجراست.'
          : 'پیش از شروع، بررسی می‌شود که این وعده را ندارید و موجودی کافی است.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (refusal != null)
            _Banner(
              icon: Icons.block,
              text: refusal!,
              background: theme.colorScheme.errorContainer,
              foreground: theme.colorScheme.onErrorContainer,
            )
          else if (summary != null)
            _Banner(
              icon: Icons.check_circle_outline,
              text: summary!,
              background: theme.colorScheme.secondaryContainer,
              foreground: theme.colorScheme.onSecondaryContainer,
            ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: isRunning
                  ? onStop
                  : (onStart == null || refusal != null ? null : onStart),
              icon: Icon(isRunning ? Icons.stop : Icons.play_arrow),
              label: Text(isRunning ? 'توقف شکار' : 'شروع شکار'),
            ),
          ),
        ],
      ),
    );
  }
}

/// A coloured message block.
class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.text,
    required this.background,
    required this.foreground,
  });

  final IconData icon;
  final String text;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: background,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: foreground),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(color: foreground),
            ),
          ),
        ],
      ),
    );
  }
}

/// The meal slot's name, in the portal's own words.
String mealSlotPersian(MealSlot slot) {
  switch (slot) {
    case MealSlot.breakfast:
      return 'صبحانه';
    case MealSlot.lunch:
      return 'ناهار';
    case MealSlot.dinner:
      return 'شام';
  }
}

/// Asks the user to accept the ban risk of a fast rate.
///
/// A **modal**, not a snackbar, because it must be acknowledged rather than
/// merely seen. The default focus is on cancel, so a stray Enter does not
/// accept a risk the user did not mean to take.
///
/// Returns true when the user accepted.
Future<bool> confirmRiskAcknowledgement(
  BuildContext context, {
  required Duration interval,
  required int projectedRequests,
}) async {
  final accepted = await showDialog<bool>(
    context: context,
    builder: (context) => _RiskDialog(
      interval: interval,
      projectedRequests: projectedRequests,
    ),
  );
  return accepted ?? false;
}

/// The risk dialog.
class _RiskDialog extends StatelessWidget {
  const _RiskDialog({
    required this.interval,
    required this.projectedRequests,
  });

  final Duration interval;
  final int projectedRequests;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('هشدار ریسک مسدود شدن حساب'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'بررسی با فاصله کمتر از ۱۰ ثانیه، احتمال مسدود شدن یا محدود شدن '
            'حساب را به‌طور قابل توجهی بالا می‌برد.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 10),
          Text(
            'این ریسک روی خودِ حساب است: در صورت مسدود شدن، همه بخش‌های دیگر '
            'برنامه هم از کار می‌افتند، نه فقط شکار.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 10),
          Text(
            'در این بازه حدود ${toPersianDigits(projectedRequests)} درخواست '
            'فرستاده می‌شود.',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('انصراف'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('می‌پذیرم'),
        ),
      ],
    );
  }
}
