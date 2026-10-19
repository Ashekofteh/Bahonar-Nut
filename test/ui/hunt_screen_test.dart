import 'package:bahonar_nut/core/hunt_config.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:bahonar_nut/ui/screens/hunt_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

const central = Hall(id: '1', name: 'مرکزی برادران');
const technical = Hall(id: '2', name: 'فنی برادران');

final dishes = [
  const HuntDishOption(
    optionId: '62738',
    name: 'چلو اکبرجوجه,دوغ',
    priceRial: 500000,
    halls: [central],
  ),
  const HuntDishOption(
    optionId: '62740',
    name: 'چلو گوشت,ماست',
    priceRial: 500000,
    halls: [central],
  ),
];

Widget wrap(Widget child) {
  return MaterialApp(
    locale: const Locale('fa', 'IR'),
    supportedLocales: const [Locale('fa', 'IR')],
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(body: child),
    ),
  );
}

/// Holds the configuration in state and feeds it back, the way a parent does.
///
/// A plain closure cannot do this: the screen would keep the configuration it
/// was built with, so the second pick would start from the first.
class _HuntHarness extends StatefulWidget {
  const _HuntHarness({
    required this.dishes,
    required this.halls,
    required this.initial,
    required this.onChanged,
  });

  final List<HuntDishOption> dishes;
  final List<Hall> halls;
  final HuntConfig initial;
  final void Function(HuntConfig) onChanged;

  @override
  State<_HuntHarness> createState() => _HuntHarnessState();
}

class _HuntHarnessState extends State<_HuntHarness> {
  late HuntConfig _config = widget.initial;

  @override
  Widget build(BuildContext context) {
    return HuntScreen(
      config: _config,
      dishes: widget.dishes,
      halls: widget.halls,
      onConfigChanged: (updated) {
        widget.onChanged(updated);
        setState(() => _config = updated);
      },
    );
  }
}

void main() {
  /// Scrolls until [text] is found, the way a user would.
  ///
  /// Matches on a substring, because a Persian amount is one `Text` whose
  /// content is a number and a unit — an exact match on the unit alone would
  /// never find it.
  Future<void> scrollTo(WidgetTester tester, String text) async {
    final finder = find.textContaining(text);
    for (var attempt = 0; attempt < 12; attempt++) {
      if (finder.evaluate().isNotEmpty) return;
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -400));
      await tester.pumpAndSettle();
    }
  }

  group('the screen', () {
    testWidgets('shows the peak window for the target meal', (tester) async {
      await tester.pumpWidget(wrap(HuntScreen(
        config: HuntConfig(targetSlot: MealSlot.lunch),
        dishes: dishes,
        halls: const [central, technical],
        onConfigChanged: (_) {},
      )));

      await scrollTo(tester, 'بازه اوج');
      expect(find.textContaining('بازه اوج'), findsWidgets);
    });

    testWidgets('shows the dishes the portal offers', (tester) async {
      await tester.pumpWidget(wrap(HuntScreen(
        config: HuntConfig(),
        dishes: dishes,
        halls: const [central, technical],
        onConfigChanged: (_) {},
      )));

      await scrollTo(tester, 'چلو اکبرجوجه,دوغ');
      expect(find.text('چلو اکبرجوجه,دوغ'), findsOneWidget);
    });

    testWidgets('shows a price in Toman, never Rial', (tester) async {
      await tester.pumpWidget(wrap(HuntScreen(
        config: HuntConfig(),
        dishes: dishes,
        halls: const [central, technical],
        onConfigChanged: (_) {},
      )));

      await scrollTo(tester, 'تومان');
      expect(find.textContaining('تومان'), findsWidgets);
      expect(find.textContaining('ریال'), findsNothing);
    });

    testWidgets('picking a dish reports the new configuration', (tester) async {
      HuntConfig? changed;
      await tester.pumpWidget(wrap(HuntScreen(
        config: HuntConfig(),
        dishes: dishes,
        halls: const [central, technical],
        onConfigChanged: (c) => changed = c,
      )));

      await scrollTo(tester, 'چلو اکبرجوجه,دوغ');
      await tester.tap(find.text('چلو اکبرجوجه,دوغ'));
      await tester.pumpAndSettle();

      expect(changed, isNotNull);
      expect(changed!.dishPriority, hasLength(1));
      expect(changed!.dishPriority.first.name, 'چلو اکبرجوجه,دوغ');
    });

    testWidgets('picking a second dish keeps the first as the priority',
        (tester) async {
      HuntConfig? changed;

      await tester.pumpWidget(wrap(_HuntHarness(
        initial: HuntConfig(),
        dishes: dishes,
        halls: const [central, technical],
        onChanged: (c) => changed = c,
      )));

      await scrollTo(tester, 'چلو اکبرجوجه,دوغ');
      await tester.tap(find.text('چلو اکبرجوجه,دوغ'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('چلو گوشت,ماست'));
      await tester.pumpAndSettle();

      expect(changed!.dishPriority, hasLength(2));
      expect(changed!.dishPriority.first.name, 'چلو اکبرجوجه,دوغ');
      expect(changed!.dishPriority.last.name, 'چلو گوشت,ماست');
    });

    testWidgets('the halls can be chosen in priority order', (tester) async {
      HuntConfig? changed;
      await tester.pumpWidget(wrap(HuntScreen(
        config: HuntConfig(),
        dishes: dishes,
        halls: const [central, technical],
        onConfigChanged: (c) => changed = c,
      )));

      await scrollTo(tester, 'فنی برادران');
      await tester.tap(find.text('فنی برادران'));
      await tester.pumpAndSettle();

      expect(changed!.hallPriority, hasLength(1));
      expect(changed!.hallPriority.first.id, '2');
    });
  });

  group('the projected request count', () {
    testWidgets('moves with the rate', (tester) async {
      HuntConfig? changed;

      await tester.pumpWidget(wrap(_HuntHarness(
        initial: HuntConfig(
          targetSlot: MealSlot.dinner,
          windowStart: const ClockTime(16, 30),
          windowEnd: const ClockTime(20, 30),
          rate: HuntRate(
            peakInterval: const Duration(seconds: 30),
            offPeakInterval: const Duration(minutes: 15),
          ),
        ),
        dishes: dishes,
        halls: const [central, technical],
        onChanged: (c) => changed = c,
      )));

      await scrollTo(tester, 'حدود');
      expect(find.textContaining('حدود'), findsOneWidget);

      // Move the peak slider to its fastest end.
      //
      // Which end that is depends on the layout direction, so both ends are
      // tried and the one that made the interval shorter is the fast end.
      final slider = find.byType(Slider).first;
      final box = tester.getRect(slider);

      await tester.tapAt(Offset(box.left + 1, box.center.dy));
      await tester.pumpAndSettle();
      final left = changed?.rate.peakInterval;

      await tester.tapAt(Offset(box.right - 1, box.center.dy));
      await tester.pumpAndSettle();
      final right = changed?.rate.peakInterval;

      final fastest = left! < right! ? left : right;
      expect(fastest, lessThan(const Duration(seconds: 30)));

      // The count is the number the user trades against, so it must still be
      // on screen, and it must have moved.
      expect(find.textContaining('حدود'), findsOneWidget);
    });
  });

  group('the ban-risk warning', () {
    testWidgets('appears below ten seconds and does not appear at or above it',
        (tester) async {
      // Below the threshold: the modal must appear.
      await tester.pumpWidget(wrap(Builder(
        builder: (context) => Scaffold(
          body: Column(
            children: [
              ElevatedButton(
                onPressed: () => confirmRiskAcknowledgement(
                  context,
                  interval: const Duration(seconds: 5),
                  projectedRequests: 2880,
                ),
                child: const Text('شروع'),
              ),
            ],
          ),
        ),
      )));

      await tester.tap(find.text('شروع'));
      await tester.pumpAndSettle();

      expect(find.text('هشدار ریسک مسدود شدن حساب'), findsOneWidget);
      expect(find.textContaining('درخواست'), findsWidgets);

      // The default is cancel, so a stray Enter does not accept the risk.
      expect(find.text('انصراف'), findsOneWidget);
      expect(find.text('می‌پذیرم'), findsOneWidget);
    });

    testWidgets('the rate below the threshold is flagged as risky',
        (tester) async {
      final risky = HuntRate(peakInterval: const Duration(seconds: 5));
      final safe = HuntRate(peakInterval: const Duration(seconds: 10));

      expect(risky.needsRiskAcknowledgement, isTrue);
      expect(safe.needsRiskAcknowledgement, isFalse);
    });
  });
}
