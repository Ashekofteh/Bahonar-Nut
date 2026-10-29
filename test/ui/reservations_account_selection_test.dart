import 'package:bahonar_nut/core/account_store.dart';
import 'package:bahonar_nut/core/local_meal_store.dart';
import 'package:bahonar_nut/core/meal_invariant.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:bahonar_nut/ui/app_state.dart';
import 'package:bahonar_nut/ui/screens/booking_sheet.dart';
import 'package:bahonar_nut/ui/screens/reservations_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget wrap(AppState state, Widget child) {
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
        child: child,
      ),
    );
  }

  testWidgets('ReservationsScreen displays account picker and switches between multiple accounts',
      (tester) async {
    final state = AppState(
      accountStore: InMemoryAccountStore(),
      reminderConfigStore: InMemoryReminderConfigStore(),
      huntConfigStore: InMemoryHuntConfigStore(),
      mealStore: LocalMealStore(),
    );

    // Account 1: Ali (ID: 400111)
    await state.upsertAccount(studentId: '400111', alias: 'علی');
    // Account 2: Reza (ID: 400222)
    await state.upsertAccount(studentId: '400222', alias: 'رضا');
    await state.load();

    final acc1 = state.accounts[0].id;
    final acc2 = state.accounts[1].id;

    state.setBalance(acc1, 350000); // 35,000 Toman
    state.setBalance(acc2, 700000); // 70,000 Toman

    final date = DateTime.utc(2026, 10, 24);
    // Put meal for Ali
    state.mealStore.put(StoredMeal(
      accountId: acc1,
      date: date,
      slot: MealSlot.lunch,
      source: MealSource.weeklyReservation,
      capturedAt: date,
      dishName: 'چلو قرمه سبزی',
      hallName: 'مرکزی',
      priceRial: 350000,
    ));

    // Put meal for Reza
    state.mealStore.put(StoredMeal(
      accountId: acc2,
      date: date,
      slot: MealSlot.lunch,
      source: MealSource.weeklyReservation,
      capturedAt: date,
      dishName: 'زرشک پلو با مرغ',
      hallName: 'مرکزی',
      priceRial: 700000,
    ));

    final clock = FixedServerClock.now(DateTime.utc(2026, 10, 24, 12));

    AccountId? switchedAccount;
    await tester.pumpWidget(
      wrap(
        state,
        ReservationsScreen(
          state: state,
          clock: clock,
          onAccountChanged: (id) => switchedAccount = id,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Verify account picker is rendered
    expect(find.text('رزرو برای حساب:'), findsOneWidget);
    expect(find.textContaining('علی'), findsWidgets);
    expect(find.textContaining('رضا'), findsWidgets);

    // Initial account should show Ali's meal
    expect(find.text('چلو قرمه سبزی'), findsOneWidget);
    expect(find.text('زرشک پلو با مرغ'), findsNothing);

    // Tap Reza's chip to switch account
    await tester.tap(find.textContaining('رضا'));
    await tester.pumpAndSettle();

    // Verify callback was called with Reza's account ID
    expect(switchedAccount, acc2);
    expect(state.selectedReservationsAccountId, acc2);

    // Verify UI updated to show Reza's meal
    expect(find.text('زرشک پلو با مرغ'), findsOneWidget);
    expect(find.text('چلو قرمه سبزی'), findsNothing);
  });

  testWidgets('BookingSheet renders account badge when accountName is provided', (tester) async {
    final menu = MealMenu(
      date: DateTime.utc(2026, 10, 24),
      slot: MealSlot.lunch,
      halls: const [Hall(id: '1', name: 'مرکزی')],
      dishes: const [MenuOption(id: '10', name: 'چلو کباب', priceRial: 500000)],
      reservable: true,
    );

    await tester.pumpWidget(
      wrap(
        AppState(
          accountStore: InMemoryAccountStore(),
          reminderConfigStore: InMemoryReminderConfigStore(),
          huntConfigStore: InMemoryHuntConfigStore(),
        ),
        Scaffold(
          body: BookingSheet(
            menu: menu,
            accountName: 'شریفی',
            onBook: (_) async => null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('شریفی'), findsOneWidget);
    expect(find.byIcon(Icons.person), findsOneWidget);
  });
}
