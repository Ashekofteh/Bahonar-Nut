import 'package:bahonar_nut/core/bank_card.dart';
import 'package:bahonar_nut/ui/screens/top_up_gateway_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('TopUpGatewayScreen renders desktop instructions and copy card actions', (tester) async {
    String clipboardDataText = '';
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall methodCall) async {
        if (methodCall.method == 'Clipboard.setData') {
          final args = methodCall.arguments as Map<dynamic, dynamic>;
          clipboardDataText = args['text'] as String? ?? '';
          return null;
        } else if (methodCall.method == 'Clipboard.getData') {
          return <String, dynamic>{'text': clipboardDataText};
        }
        return null;
      },
    );

    final cards = [
      const SavedBankCard(
        id: 'card_1',
        title: 'بلو بانک',
        pan: '6219861012345678',
        cvv2: '123',
        expMonth: '12',
        expYear: '05',
      ),
    ];

    var returnedCalled = false;
    Uri? launchedUri;

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('fa', 'IR'),
        supportedLocales: const [Locale('fa', 'IR')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: TopUpGatewayScreen(
          gateway: Uri.parse('https://sep.shaparak.ir/OnlinePayment/test'),
          cookies: const {'ASP.NET_SessionId': 'session123'},
          portalHost: 'nut.uk.ac.ir',
          savedCards: cards,
          autoLaunchBrowser: false,
          onLaunchExternalBrowser: (uri) async => launchedUri = uri,
          onReturned: () => returnedCalled = true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Verify desktop card content is rendered on desktop (Windows / macOS / Linux)
    expect(find.text('انتقال به درگاه رسمی پرداخت شاپرک'), findsOneWidget);
    expect(find.text('تکمیل و ثبت نهایی در برنامه'), findsOneWidget);
    expect(find.text('باز کردن مجدد درگاه'), findsOneWidget);
    expect(find.text('بلو بانک'), findsOneWidget);

    // Test clicking re-open in external browser
    await tester.ensureVisible(find.text('باز کردن مجدد درگاه'));
    await tester.tap(find.text('باز کردن مجدد درگاه'));
    await tester.pumpAndSettle();
    expect(launchedUri, Uri.parse('https://sep.shaparak.ir/OnlinePayment/test'));

    // Test copying card number
    await tester.ensureVisible(find.byTooltip('کپی شماره کارت'));
    await tester.tap(find.byTooltip('کپی شماره کارت'));
    await tester.pumpAndSettle();

    final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
    expect(clipboardData?.text, '6219861012345678');

    // Test clicking complete and return button
    await tester.ensureVisible(find.text('تکمیل و ثبت نهایی در برنامه'));
    await tester.tap(find.text('تکمیل و ثبت نهایی در برنامه'));
    await tester.pumpAndSettle();

    expect(returnedCalled, isTrue);
  });
}
