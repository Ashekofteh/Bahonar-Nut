import 'dart:io';

import 'package:bahonar_nut/adapter/cullinan_client.dart';
import 'package:bahonar_nut/adapter/cullinan_parser.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/transport/http_transport.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  final session = Session(
    account: '401405035',
    cookies: const {'ASP.NET_SessionId': 'test-session'},
    establishedAt: DateTime.utc(2026, 10, 20),
  );

  String sampleSalePage({
    String viewState = 'VS123',
    String viewStateGen = 'GEN456',
    String alert = '',
  }) =>
      '''
<!DOCTYPE html>
<html>
<body>
  <form method="post" action="./FoodBasketSale.aspx" id="MainForm">
    <input type="hidden" name="__VIEWSTATE" id="__VIEWSTATE" value="$viewState" />
    <input type="hidden" name="__VIEWSTATEGENERATOR" id="__VIEWSTATEGENERATOR" value="$viewStateGen" />
    <div id="cphMain_alertBox" class="alertBox" style="${alert.isEmpty ? 'display:none;' : ''}">
      <label id="cphMain_alertBoxValue">$alert</label>
    </div>
    <input name="ctl00\$cphMain\$txtDate" type="text" id="cphMain_txtDate" value="1405/07/26" />
    <select name="ctl00\$cphMain\$drpReserveType" id="cphMain_drpReserveType">
      <option value="0">رزرو هفتگی</option>
      <option value="1">روزفروش</option>
    </select>
    <select name="ctl00\$cphMain\$drpFoodType" id="cphMain_drpFoodType">
      <option value="1">صبحانه</option>
      <option value="2">ناهار</option>
      <option value="3">شام</option>
    </select>
    <input name="ctl00\$cphMain\$btnFoodReload" type="submit" id="cphMain_btnFoodReload" value="بارگذاری غذا" />
  </form>
</body>
</html>
''';

  group('CullinanParser - FoodBasketSale.aspx', () {
    test('saleFormBody constructs valid WebForms post payload', () {
      final html = sampleSalePage(viewState: 'MY_VS', viewStateGen: 'MY_GEN');
      final body = CullinanParser.saleFormBody(
        html,
        jalaliDate: '1405/08/04',
        slot: MealSlot.lunch,
      );

      expect(body['__VIEWSTATE'], 'MY_VS');
      expect(body['__VIEWSTATEGENERATOR'], 'MY_GEN');
      expect(body['__VIEWSTATEENCRYPTED'], '');
      expect(body['__EVENTTARGET'], '');
      expect(body['__EVENTARGUMENT'], '');
      expect(body[r'ctl00$cphMain$txtDate'], '1405/08/04');
      expect(body[r'ctl00$cphMain$drpReserveType'], '0');
      expect(body[r'ctl00$cphMain$drpFoodType'], '2'); // lunch = 2
      expect(body[r'ctl00$cphMain$btnFoodReload'], 'بارگذاری غذا');
    });

    test('drpFoodType maps all meal slots correctly', () {
      final html = sampleSalePage();
      expect(
        CullinanParser.saleFormBody(html, jalaliDate: '1405/08/01', slot: MealSlot.breakfast)[r'ctl00$cphMain$drpFoodType'],
        '1',
      );
      expect(
        CullinanParser.saleFormBody(html, jalaliDate: '1405/08/01', slot: MealSlot.lunch)[r'ctl00$cphMain$drpFoodType'],
        '2',
      );
      expect(
        CullinanParser.saleFormBody(html, jalaliDate: '1405/08/01', slot: MealSlot.dinner)[r'ctl00$cphMain$drpFoodType'],
        '3',
      );
    });

    test('parseSaleAlert extracts alert text when present', () {
      final htmlWithAlert = sampleSalePage(alert: 'غذایی جهت فروش یافت نشد.');
      expect(
        CullinanParser.parseSaleAlert(htmlWithAlert),
        'غذایی جهت فروش یافت نشد.',
      );

      final htmlWithoutAlert = sampleSalePage(alert: '');
      expect(CullinanParser.parseSaleAlert(htmlWithoutAlert), isNull);
    });
  });

  group('CullinanPortalClient.listMealForSale', () {
    test('succeeds when portal posts without alert box error', () async {
      final sentBodies = <Map<String, String>>[];
      final requestUrls = <String>[];

      final transport = PortalTransport(
        baseUri: Uri.parse('https://nut.uk.ac.ir/'),
        httpClient: MockClient((request) async {
          requestUrls.add('${request.method} ${request.url.path}');
          if (request.method == 'POST') {
            sentBodies.add(request.bodyFields);
          }

          if (request.url.path.contains('FoodBasketSale.aspx')) {
            if (request.method == 'GET') {
              return http.Response(
                sampleSalePage(viewState: 'GET_VS', viewStateGen: 'GET_GEN'),
                200,
                headers: {'content-type': 'text/html; charset=utf-8'},
              );
            } else if (request.method == 'POST') {
              // Return clean page indicating accepted reload
              return http.Response(
                sampleSalePage(viewState: 'POST_VS', viewStateGen: 'POST_GEN', alert: ''),
                200,
                headers: {'content-type': 'text/html; charset=utf-8'},
              );
            }
          }
          return http.Response('Not Found', 404);
        }),
      );

      final client = CullinanPortalClient(transport: transport);
      // 2026-10-25 = Sunday 1405/08/03
      final result = await client.listMealForSale(
        session,
        date: DateTime.utc(2026, 10, 25),
        slot: MealSlot.lunch,
      );

      expect(result, isA<SaleListingSucceeded>());
      expect(requestUrls, [
        'GET /FoodBasket/FoodBasketSale.aspx',
        'POST /FoodBasket/FoodBasketSale.aspx',
      ]);
      expect(sentBodies.single[r'ctl00$cphMain$txtDate'], '1405/08/03');
      expect(sentBodies.single[r'ctl00$cphMain$drpFoodType'], '2');
      expect(sentBodies.single[r'ctl00$cphMain$btnFoodReload'], 'بارگذاری غذا');
    });

    test('succeeds when alert contains success message', () async {
      final transport = PortalTransport(
        baseUri: Uri.parse('https://nut.uk.ac.ir/'),
        httpClient: MockClient((request) async {
          if (request.method == 'GET') {
            return http.Response(sampleSalePage(), 200, headers: {'content-type': 'text/html; charset=utf-8'});
          }
          return http.Response(
            sampleSalePage(alert: 'عملیات با موفقیت انجام شد.'),
            200,
            headers: {'content-type': 'text/html; charset=utf-8'},
          );
        }),
      );

      final client = CullinanPortalClient(transport: transport);
      final result = await client.listMealForSale(
        session,
        date: DateTime.utc(2026, 10, 25),
        slot: MealSlot.dinner,
      );

      expect(result, isA<SaleListingSucceeded>());
      expect((result as SaleListingSucceeded).message, contains('موفقیت'));
    });

    test('refuses when alert indicates error or no meal found', () async {
      final transport = PortalTransport(
        baseUri: Uri.parse('https://nut.uk.ac.ir/'),
        httpClient: MockClient((request) async {
          if (request.method == 'GET') {
            return http.Response(sampleSalePage(), 200, headers: {'content-type': 'text/html; charset=utf-8'});
          }
          return http.Response(
            sampleSalePage(alert: 'غذایی جهت فروش در این وعده وجود ندارد.'),
            200,
            headers: {'content-type': 'text/html; charset=utf-8'},
          );
        }),
      );

      final client = CullinanPortalClient(transport: transport);
      final result = await client.listMealForSale(
        session,
        date: DateTime.utc(2026, 10, 25),
        slot: MealSlot.breakfast,
      );

      expect(result, isA<SaleListingRefused>());
      expect((result as SaleListingRefused).reason, 'غذایی جهت فروش در این وعده وجود ندارد.');
    });

    test('refuses when redirected to login page due to expired session', () async {
      final loginHtml = '<html><input name="txtUsernamePlain" id="txtUsernamePlain" /></html>';
      final transport = PortalTransport(
        baseUri: Uri.parse('https://nut.uk.ac.ir/'),
        httpClient: MockClient((request) async {
          return http.Response(loginHtml, 200, headers: {'content-type': 'text/html; charset=utf-8'});
        }),
      );

      final client = CullinanPortalClient(transport: transport);
      final result = await client.listMealForSale(
        session,
        date: DateTime.utc(2026, 10, 25),
        slot: MealSlot.lunch,
      );

      expect(result, isA<SaleListingRefused>());
      expect((result as SaleListingRefused).reason, contains('نشست'));
    });

    test('returns ambiguous on transport exception', () async {
      final transport = PortalTransport(
        baseUri: Uri.parse('https://nut.uk.ac.ir/'),
        httpClient: MockClient((request) async {
          throw const SocketException('Connection reset by peer');
        }),
      );

      final client = CullinanPortalClient(transport: transport);
      final result = await client.listMealForSale(
        session,
        date: DateTime.utc(2026, 10, 25),
        slot: MealSlot.lunch,
      );

      expect(result, isA<SaleListingAmbiguous>());
    });
  });
}
