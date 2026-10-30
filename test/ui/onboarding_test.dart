import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bahonar_nut/ui/screens/onboarding_sheet.dart';
import '../helpers/memory_stores.dart';

void main() {
  group('Onboarding Guide Walkthrough', () {
    late MemoryPlainStore plainStore;

    setUp(() {
      plainStore = MemoryPlainStore();
    });

    Widget wrap(Widget child) {
      return MaterialApp(
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [Locale('fa')],
        home: Scaffold(body: child),
      );
    }

    testWidgets('navigates through all 4 slides and records completion', (tester) async {
      bool completed = false;

      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showOnboardingGuide(
                context,
                plainStore: plainStore,
                onComplete: () => completed = true,
              ),
              child: const Text('Launch Onboarding'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Launch Onboarding'));
      await tester.pumpAndSettle();

      // Slide 1
      expect(find.text('ورود هوشمند و بدون معطلی'), findsOneWidget);
      expect(find.text('گام ۱ از ۴'), findsOneWidget);
      expect(find.text('رد شدن'), findsOneWidget);

      // Advance to Slide 2
      await tester.tap(find.text('بعدی'));
      await tester.pumpAndSettle();

      expect(find.text('دریافت منو و رزرو غذا'), findsOneWidget);
      expect(find.textContaining('دکمه به‌روزرسانی (رفرش 🔄)'), findsOneWidget);
      expect(find.text('گام ۲ از ۴'), findsOneWidget);

      // Advance to Slide 3
      await tester.tap(find.text('بعدی'));
      await tester.pumpAndSettle();

      expect(find.text('سبد غذایی و شکار خودکار'), findsOneWidget);
      expect(find.text('گام ۳ از ۴'), findsOneWidget);

      // Advance to Slide 4
      await tester.tap(find.text('بعدی'));
      await tester.pumpAndSettle();

      expect(find.text('یادآورها و فیش فراموشی کارت'), findsOneWidget);
      expect(find.text('شروع کار با سِلفیار'), findsOneWidget);
      expect(find.text('گام ۴ از ۴'), findsOneWidget);

      // Finish Onboarding
      await tester.tap(find.text('شروع کار با سِلفیار'));
      await tester.pumpAndSettle();

      expect(completed, isTrue);
      final storedFlag = await plainStore.readBool('onboarding_completed');
      expect(storedFlag, isTrue);
    });

    testWidgets('tapping Skip finishes immediately and saves completion', (tester) async {
      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showOnboardingGuide(
                context,
                plainStore: plainStore,
              ),
              child: const Text('Launch'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Launch'));
      await tester.pumpAndSettle();

      expect(find.text('ورود هوشمند و بدون معطلی'), findsOneWidget);

      await tester.tap(find.text('رد شدن'));
      await tester.pumpAndSettle();

      expect(find.text('ورود هوشمند و بدون معطلی'), findsNothing);
      final storedFlag = await plainStore.readBool('onboarding_completed');
      expect(storedFlag, isTrue);
    });
  });
}
