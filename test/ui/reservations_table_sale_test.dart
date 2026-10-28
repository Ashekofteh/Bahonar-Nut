import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/ui/reservation_table_model.dart';
import 'package:bahonar_nut/ui/screens/reservations_table.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget wrap(Widget child) {
    return MaterialApp(
      locale: const Locale('fa', 'IR'),
      supportedLocales: const [Locale('fa', 'IR')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(
        body: Directionality(
          textDirection: TextDirection.rtl,
          child: child,
        ),
      ),
    );
  }

  final testDate = DateTime.utc(2026, 10, 20);

  group('ReservationsTable - Food Basket Sale action', () {
    testWidgets('renders storefront button for heldLocked row when onSell is provided',
        (tester) async {
      DateTime? soldDate;
      MealSlot? soldSlot;

      final rows = [
        MealRow(
          date: testDate,
          slot: MealSlot.lunch,
          status: MealRowStatus.heldLocked,
          dishName: 'چلو قرمه سبزی',
          hallName: 'مرکزی برادران',
          priceRial: 400000,
        ),
      ];

      await tester.pumpWidget(
        wrap(
          ReservationsTable(
            rows: rows,
            onBook: (_, _) {},
            onCancel: (_, _) {},
            onSell: (date, slot) {
              soldDate = date;
              soldSlot = slot;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      final sellButtonFinder = find.widgetWithIcon(IconButton, Icons.storefront_outlined);
      expect(sellButtonFinder, findsOneWidget);

      await tester.tap(sellButtonFinder);
      await tester.pump();

      expect(soldDate, testDate);
      expect(soldSlot, MealSlot.lunch);
    });

    testWidgets('disables sell button when row is marked busy', (tester) async {
      final rows = [
        MealRow(
          date: testDate,
          slot: MealSlot.lunch,
          status: MealRowStatus.heldLocked,
          dishName: 'چلو قرمه سبزی',
          hallName: 'مرکزی برادران',
          priceRial: 400000,
        ),
      ];

      await tester.pumpWidget(
        wrap(
          ReservationsTable(
            rows: rows,
            busy: true,
            busyKey: '2026-10-20|lunch',
            onBook: (_, _) {},
            onCancel: (_, _) {},
            onSell: (_, _) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      final button = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.storefront_outlined),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('renders lock clock icon when onSell is null', (tester) async {
      final rows = [
        MealRow(
          date: testDate,
          slot: MealSlot.lunch,
          status: MealRowStatus.heldLocked,
          dishName: 'چلو قرمه سبزی',
        ),
      ];

      await tester.pumpWidget(
        wrap(
          ReservationsTable(
            rows: rows,
            onBook: (_, _) {},
            onCancel: (_, _) {},
            onSell: null,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('فروش در سبد غذایی'), findsNothing);
      expect(find.byIcon(Icons.lock_clock_outlined), findsOneWidget);
    });

    testWidgets('bought row renders lock icon and no sell button', (tester) async {
      final rows = [
        MealRow(
          date: testDate,
          slot: MealSlot.lunch,
          status: MealRowStatus.bought,
          dishName: 'چلو اکبرجوجه',
        ),
      ];

      await tester.pumpWidget(
        wrap(
          ReservationsTable(
            rows: rows,
            onBook: (_, _) {},
            onCancel: (_, _) {},
            onSell: (_, _) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('فروش در سبد غذایی'), findsNothing);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    });
  });
}
