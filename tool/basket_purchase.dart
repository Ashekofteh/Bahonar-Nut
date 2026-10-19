/// Instrumented Food Basket purchase.
///
/// A basket purchase is IRREVERSIBLE: there is no cancel and no resale. So this
/// tool is built to leave a complete record, and to fail safe.
///
/// ## Two modes
///
///   --inspect   read-only. Shows exactly what WOULD be posted. Spends nothing.
///   --execute   performs the purchase.
///
/// Both modes share the same parsing and the same body construction, so what
/// --inspect shows is what --execute sends.
///
/// ## Why there is no automatic fallback to the second hall
///
/// The user asked for Central (مرکزی) first, with Engineering (فنی) as the
/// fallback. But after a POST, the outcome can be AMBIGUOUS: a timeout or a
/// dropped connection does not say whether the purchase landed. If a first
/// attempt at hall 1 succeeded and we could not tell, trying hall 2 would buy
/// the SAME meal a second time — and a basket purchase cannot be cancelled.
///
/// So the rule is: after each POST, establish ground truth (credit + ledger).
/// Only if the first attempt is *definitively* unsuccessful is the fallback
/// attempted. An ambiguous result stops the run.
///
/// ## The full form state
///
/// The buy page is a grid whose checkboxes mean "this meal is held". An
/// ASP.NET checkbox ABSENT from a POST reads as UNCHECKED. So the post is the
/// complete current form state with one row's fields changed - which is what a
/// browser sends, and what keeps the account's other meals from being
/// silently released.
///
/// Usage:
///   `dart run tool/basket_purchase.dart <studentId> <password> --inspect`
///   `dart run tool/basket_purchase.dart <studentId> <password> --execute`
// One-shot live action tool: stdout printing is the entire point.
// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings

library;

import 'dart:io';

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/transport/http_transport.dart';

const _base = 'https://nut.uk.ac.ir/';

late Directory captureDir;

void save(String name, String content) {
  File('${captureDir.path}/$name').writeAsStringSync(content);
  print('   [capture] $name (${content.length} chars)');
}

/// One row of the buy grid.
class BasketRow {
  BasketRow({
    required this.slotName,
    required this.slot,
    required this.checkboxName,
    required this.checked,
    required this.disabled,
    required this.selfName,
    required this.selfValue,
    required this.selfOptions,
    required this.foodName,
    required this.foodValue,
    required this.foodOptions,
    required this.countName,
    required this.countValue,
    required this.amount,
    required this.status,
  });

  final String slotName;
  final MealSlot slot;
  final String checkboxName;
  final bool checked;
  final bool disabled;
  final String selfName;
  final String selfValue;
  final List<MapEntry<String, String>> selfOptions;
  final String foodName;
  final String foodValue;
  final List<MapEntry<String, String>> foodOptions;
  final String countName;
  final String countValue;
  final String amount;
  final String status;

  @override
  String toString() => '$slotName checked=$checked disabled=$disabled '
      'options=${foodOptions.length}';
}

enum MealSlot { breakfast, lunch, dinner }

const _slotNames = {
  'صبحانه': MealSlot.breakfast,
  'ناهار': MealSlot.lunch,
  'شام': MealSlot.dinner,
};

/// Parses the buy grid.
List<BasketRow> parseBuyRows(String html) {
  final table = RegExp('<table[^>]*id="[^"]*grdFoodBasketReservation"[^>]*>(.*?)</table>',
          dotAll: true)
      .firstMatch(html);
  if (table == null) return const [];

  final out = <BasketRow>[];
  for (final m in RegExp(r'<tr[^>]*>(.*?)</tr>', dotAll: true)
      .allMatches(table.group(1)!)) {
    final raw = m.group(1)!;
    final cells = RegExp(r'<td[^>]*>(.*?)</td>', dotAll: true)
        .allMatches(raw)
        .map((c) => c.group(1)!)
        .toList();
    if (cells.length < 4) continue;

    final slotName = _text(cells[1]).trim();
    final slot = _slotNames[slotName];
    if (slot == null) continue;

    final cb = RegExp(r'<input[^>]*type="checkbox"[^>]*>', dotAll: true)
        .firstMatch(raw);
    final cbTag = cb?.group(0) ?? '';
    final self = _select(cells[2], 'drpSelf');
    final food = _select(cells[3], 'drpFood');
    final count = _select(cells[4], 'drpFoodCount');

    out.add(BasketRow(
      slotName: slotName,
      slot: slot,
      checkboxName: _attr(cbTag, 'name'),
      checked: cbTag.contains('checked'),
      disabled: cbTag.contains('disabled'),
      selfName: self?.name ?? '',
      selfValue: self?.value ?? '',
      selfOptions: self?.options ?? const [],
      foodName: food?.name ?? '',
      foodValue: food?.value ?? '',
      foodOptions: food?.options ?? const [],
      countName: count?.name ?? '',
      countValue: count?.value ?? '1',
      amount: cells.length > 6 ? _text(cells[6]) : '',
      status: cells.length > 7 ? _text(cells[7]) : '',
    ));
  }
  return out;
}

class _Sel {
  _Sel(this.name, this.value, this.options);
  final String name;
  final String value;
  final List<MapEntry<String, String>> options;
}

_Sel? _select(String cell, String suffix) {
  final m = RegExp('<select[^>]*name="([^"]*' + RegExp.escape(suffix) +
          r')"[^>]*>(.*?)</select>',
          dotAll: true)
      .firstMatch(cell);
  if (m == null) return null;

  final options = <MapEntry<String, String>>[];
  String? selected;
  for (final o in RegExp(r'<option([^>]*)>(.*?)</option>', dotAll: true)
      .allMatches(m.group(2)!)) {
    final attrs = o.group(1)!;
    final value = _attr(attrs, 'value');
    final text = _text(o.group(2)!);
    final v = value.isEmpty ? text : value;
    options.add(MapEntry(v, text));
    if (selected == null && attrs.contains('selected')) selected = v;
  }
  return _Sel(m.group(1)!, selected ?? '', options);
}

/// Builds the COMPLETE form state, with one row's fields changed.
///
/// The date is part of the form state too, because the buy page is filtered by
/// it.
Map<String, String> buildBuyFormState(
  String html,
  List<BasketRow> rows, {
  required String date,
  BasketRow? target,
  String? targetHall,
  String? targetFood,
}) {
  final body = <String, String>{
    '__VIEWSTATE': _input(html, '__VIEWSTATE'),
    '__VIEWSTATEGENERATOR': _input(html, '__VIEWSTATEGENERATOR'),
    '__VIEWSTATEENCRYPTED': _input(html, '__VIEWSTATEENCRYPTED'),
    '__EVENTTARGET': '',
    '__EVENTARGUMENT': '',
    'ctl00\$cphMain\$txtDate': date,
  };

  for (final row in rows) {
    if (row.selfName.isNotEmpty) body[row.selfName] = row.selfValue;
    if (row.foodName.isNotEmpty) body[row.foodName] = row.foodValue;
    if (row.countName.isNotEmpty) body[row.countName] = row.countValue;

    final isTarget = target != null && row.slot == target.slot;
    if (isTarget) {
      if (row.checkboxName.isNotEmpty) body[row.checkboxName] = 'on';
      if (targetHall != null && row.selfName.isNotEmpty) {
        body[row.selfName] = targetHall;
      }
      if (targetFood != null && row.foodName.isNotEmpty) {
        body[row.foodName] = targetFood;
      }
    } else if (row.checked && row.checkboxName.isNotEmpty) {
      // Preserve every OTHER held meal. An absent checkbox reads as unchecked,
      // so dropping it would release that meal.
      body[row.checkboxName] = 'on';
    }
  }

  body['ctl00\$cphMain\$btnSave'] = 'ذخیره';
  return body;
}

/// The account's held meals, from the weekly reservation grids.
Set<String> heldWeekly(String html) {
  final held = <String>{};
  for (final entry in [
    'grdReservationBreakfast',
    'grdReservationLunch',
    'grdReservationDinner'
  ]) {
    final t = RegExp('<table[^>]*id="[^"]*' + entry + r'"[^>]*>(.*?)</table>',
            dotAll: true)
        .firstMatch(html);
    if (t == null) continue;
    for (final m in RegExp(r'<tr[^>]*>(.*?)</tr>', dotAll: true)
        .allMatches(t.group(1)!)) {
      final raw = m.group(1)!;
      if (!raw.contains('checked="checked"')) continue;
      final cells = RegExp(r'<td[^>]*>(.*?)</td>', dotAll: true)
          .allMatches(raw)
          .map((c) => c.group(1)!)
          .toList();
      if (cells.length < 4) continue;
      final label = _text(cells[1]);
      final d = RegExp(r'\d{4}/\d{2}/\d{2}').firstMatch(label)?.group(0);
      if (d != null) held.add('$entry|$d');
    }
  }
  return held;
}

/// The transaction ledger rows, as "type|food|meal|weekday|date|count|amount".
List<String> ledgerRows(String html) {
  final t = RegExp('<table[^>]*id="[^"]*grdContent"[^>]*>(.*?)</table>', dotAll: true)
      .firstMatch(html);
  if (t == null) return const [];

  final out = <String>[];
  for (final m in RegExp(r'<tr[^>]*>(.*?)</tr>', dotAll: true)
      .allMatches(t.group(1)!)) {
    final cells = RegExp(r'<td[^>]*>(.*?)</td>', dotAll: true)
        .allMatches(m.group(1)!)
        .map((c) => _text(c.group(1)!))
        .toList();
    if (cells.isEmpty || cells.first.isEmpty) continue;
    out.add(cells.join(' | '));
  }
  return out;
}

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    print('usage: dart run tool/basket_purchase.dart <studentId> <password> '
        '--inspect|--execute');
    exitCode = 2;
    return;
  }
  final username = args[0];
  final password = args[1];
  final mode = args[2];
  final execute = mode == '--execute';
  const targetDate = '1405/07/28';
  const wantDish = 'اکبرجوجه';

  captureDir = Directory('captures')..createSync(recursive: true);
  print('=== BASKET PURCHASE (${execute ? "EXECUTE" : "INSPECT"}) '
      '${DateTime.now().toIso8601String()} ===');
  print('target: lunch on $targetDate, dish containing "$wantDish"');
  print('IMPORTANT: a basket purchase is irreversible.\n');

  final transport = PortalTransport(baseUri: Uri.parse(_base));

  try {
    // ------------------------------------------------------------- LOGIN
    final page = await transport.get(username, '/');
    final captcha =
        await transport.getBytes(username, '/UserControls/Captcha.ashx');
    final solution = CaptchaSolver().solve(captcha);
    final login = await transport.post(username, '/', body: {
      '__VIEWSTATE': _input(page.body, '__VIEWSTATE'),
      '__VIEWSTATEGENERATOR': _input(page.body, '__VIEWSTATEGENERATOR'),
      '__VIEWSTATEENCRYPTED': '',
      'txtUsername': username,
      'txtPassword': password,
      'txtCaptcha': solution.text!,
      'btnLogin': 'ورود سمت سرور ',
    });
    if (login.body.contains('txtUsernamePlain')) {
      print('!! LOGIN FAILED');
      return;
    }
    final creditBefore = _credit(login.body);
    print('login OK; credit BEFORE: $creditBefore');

    // ---------------------------------------- BASELINE (before anything)
    final weeklyBefore =
        await transport.get(username, '/Reservation/Reservation.aspx');
    final heldBefore = heldWeekly(weeklyBefore.body);
    print('held BEFORE (weekly grids): ${heldBefore.toList()..sort()}');

    final ledgerBefore =
        await transport.get(username, '/MyCullinan/MyTransaction.aspx');
    final rowsBefore = ledgerRows(ledgerBefore.body);
    print('ledger rows BEFORE: ${rowsBefore.length}');
    save('80_ledger_before.html', ledgerBefore.body);

    // ------------------------------------- THE BUY PAGE FOR THE TARGET DATE
    final buyPage = await transport.get(username, '/FoodBasket/FoodBasketBuy.aspx');
    final filtered = await _setDate(transport, username, buyPage.body, targetDate);
    save('81_buy_page_1405_07_28.html', filtered);

    final shownDate = _textById(filtered, 'cphMain_lblTodayDate');
    final dateField = _value(filtered, 'cphMain_txtDate');
    print('\n--- the buy page for the target date ---');
    print('date field: $dateField   page says: $shownDate');
    if (!dateField.contains(targetDate)) {
      print('!! the date filter did not apply (field=$dateField) - aborting');
      return;
    }

    final rows = parseBuyRows(filtered);
    print('rows: ${rows.length}');
    for (final row in rows) {
      print('  ${row.slotName.padRight(8)} checked=${row.checked} '
          'disabled=${row.disabled} amount=${row.amount} status="${row.status}"');
      print('      halls: ${row.selfOptions.map((h) => "${h.key}=${h.value}").toList()}');
      for (final o in row.foodOptions) {
        final mark = o.value.contains(wantDish) ? '   <== TARGET DISH' : '';
        print('      option ${o.key}: ${o.value}$mark');
      }
    }

    final lunch = rows.where((r) => r.slot == MealSlot.lunch).firstOrNull;
    if (lunch == null) {
      print('\n!! no lunch row on the buy page for $targetDate');
      return;
    }

    final targetOption = lunch.foodOptions
        .where((o) => o.value.contains(wantDish))
        .firstOrNull;
    if (targetOption == null) {
      print('\n!! "$wantDish" is NOT offered in the basket for $targetDate.');
      print('   available lunch options: '
          '${lunch.foodOptions.map((o) => o.value).toList()}');
      print('   NOT buying something else - the request was specific.');
      return;
    }
    print('\nTARGET DISH: option ${targetOption.key}  ${targetOption.value}');
    print('row disabled (locked): ${lunch.disabled}');

    final price = _price(targetOption.value);
    print('price: $price  (credit $creditBefore)');
    if (price != null && creditBefore != null && price > creditBefore) {
      print('!! insufficient balance; NOT buying');
      return;
    }

    // Hall preference: Central (1) first, Engineering (2) fallback.
    final halls = <String>['1', '2']
        .where((h) => lunch.selfOptions.any((o) => o.key == h))
        .toList();
    if (halls.isEmpty) {
      print('!! no hall options on the lunch row; NOT buying');
      return;
    }
    print('hall preference order: $halls '
        '(${halls.map((h) => lunch.selfOptions.firstWhere((o) => o.key == h).value).toList()})');

    // ---------------------------------------------------- THE PLAN / POST
    final planBody = buildBuyFormState(filtered, rows,
        date: targetDate,
        target: lunch,
        targetHall: halls.first,
        targetFood: targetOption.key);
    print('\n--- POST plan ---');
    print('fields: ${planBody.length}');
    print('viewstate: ${(planBody['__VIEWSTATE'] ?? '').length} chars');
    print('checkboxes sent as on: '
        '${planBody.keys.where((k) => k.contains('chkReserve')).toList()}');
    print('  drpSelf=${planBody[lunch.selfName]}  '
        'drpFood=${planBody[lunch.foodName]}  '
        'drpFoodCount=${planBody[lunch.countName]}');
    save('82_buy_post_body.txt',
        planBody.entries.map((e) => '${e.key}=${e.value}').join('\n'));

    if (!execute) {
      print('\n=== INSPECT MODE: nothing was purchased ===');
      return;
    }

    // ============================================================ PURCHASE
    print('\n=== EXECUTING ===');
    String? purchasedHall;
    for (final hall in halls) {
      print('\n--- attempting purchase with hall $hall '
          '(${lunch.selfOptions.firstWhere((o) => o.key == hall).value}) ---');

      final body = buildBuyFormState(filtered, rows,
          date: targetDate,
          target: lunch,
          targetHall: hall,
          targetFood: targetOption.key);
      body[lunch.selfName] = hall;

      final resp = await transport.post(username, '/FoodBasket/FoodBasketBuy.aspx',
          body: body);
      print('  -> status ${resp.statusCode}');
      save('83_buy_response_hall$hall.html', resp.body);

      // ---- GROUND TRUTH. Never assume; never retry on ambiguity. ----
      final creditAfter = await _creditFresh(transport, username);
      final ledgerAfter =
          await transport.get(username, '/MyCullinan/MyTransaction.aspx');
      final newRows = ledgerRows(ledgerAfter.body)
          .where((r) => !rowsBefore.contains(r))
          .toList();

      print('  credit now: $creditAfter (was $creditBefore)');
      print('  new ledger rows: ${newRows.length}');
      for (final r in newRows) {
        print('     $r');
      }

      final charged = creditAfter != null &&
          creditBefore != null &&
          creditAfter < creditBefore;
      final landed = newRows.isNotEmpty;

      if (charged || landed) {
        print('  => PURCHASE LANDED (charged=$charged, ledger=$landed)');
        purchasedHall = hall;
        break;
      }

      if (resp.statusCode >= 500) {
        print('  => server error; outcome UNKNOWN. STOPPING - a retry could '
            'buy the meal twice and neither can be cancelled.');
        return;
      }

      print('  => this attempt definitively did not purchase');
      print('     trying the next hall');
    }

    if (purchasedHall == null) {
      print('\n!! no purchase completed');
      return;
    }

    // ==================================================== FULL VERIFICATION
    print('\n--- VERIFICATION: where did the purchase land? ---');

    final weeklyAfter =
        await transport.get(username, '/Reservation/Reservation.aspx');
    save('84_weekly_after.html', weeklyAfter.body);
    final heldAfter = heldWeekly(weeklyAfter.body);
    print('held AFTER (weekly grids): ${heldAfter.toList()..sort()}');
    final lost = heldBefore.difference(heldAfter);
    print('weekly reservations LOST: ${lost.isEmpty ? "NONE" : lost.toList()}');
    final gained = heldAfter.difference(heldBefore);
    print('weekly reservations GAINED: '
        '${gained.isEmpty ? "NONE" : gained.toList()}');
    print('  ^ a GAINED weekly row means the basket purchase became a normal '
        'weekly reservation. An EMPTY gain means it landed only in the ledger.');

    final ledgerFinal =
        await transport.get(username, '/MyCullinan/MyTransaction.aspx');
    save('85_ledger_after.html', ledgerFinal.body);
    final finalRows = ledgerRows(ledgerFinal.body)
        .where((r) => !rowsBefore.contains(r))
        .toList();
    print('new ledger rows in total: ${finalRows.length}');
    for (final r in finalRows) {
      print('   $r');
    }

    final buyAfter =
        await transport.get(username, '/FoodBasket/FoodBasketBuy.aspx');
    final buyAfterFiltered = await _setDate(
        transport, username, buyAfter.body, targetDate);
    save('86_buy_page_after.html', buyAfterFiltered);
    print('\nthe buy page for $targetDate after the purchase:');
    for (final row in parseBuyRows(buyAfterFiltered)) {
      print('  ${row.slotName.padRight(8)} checked=${row.checked} '
          'disabled=${row.disabled} amount=${row.amount} status="${row.status}"');
      for (final o in row.foodOptions) {
        final mark = o.key == targetOption.key ? '   <== PURCHASED' : '';
        print('      option ${o.key}: ${o.value}$mark');
      }
    }

    print('\ncredit NOW: ${await _creditFresh(transport, username)}');
  } catch (e, st) {
    print('EXCEPTION: $e');
    print(st.toString().split('\n').take(10).join('\n'));
    print('\nNOTE: if the failure happened after a POST, the outcome may be '
        'ambiguous - do NOT retry. Check the ledger and the credit first.');
  } finally {
    transport.close();
  }
}

/// Applies the buy page's date filter, returning the filtered page.
Future<String> _setDate(
  PortalTransport transport,
  String username,
  String html,
  String date,
) async {
  final resp = await transport.post(username, '/FoodBasket/FoodBasketBuy.aspx',
      body: {
        '__VIEWSTATE': _input(html, '__VIEWSTATE'),
        '__VIEWSTATEGENERATOR': _input(html, '__VIEWSTATEGENERATOR'),
        '__EVENTTARGET': '',
        '__EVENTARGUMENT': '',
        'ctl00\$cphMain\$txtDate': date,
        'ctl00\$cphMain\$imgbtnGoToDate.x': '1',
        'ctl00\$cphMain\$imgbtnGoToDate.y': '1',
      });
  return resp.body;
}

/// Reads the credit from a FRESH page, so a stale render cannot mislead.
Future<int?> _creditFresh(PortalTransport transport, String username) async {
  final resp = await transport.get(username, '/Reservation/Reservation.aspx');
  return _credit(resp.body);
}

int? _price(String text) {
  final buffer = StringBuffer();
  for (final rune in text.runes) {
    if (rune >= 0x06F0 && rune <= 0x06F9) {
      buffer.writeCharCode(rune - 0x06F0 + 0x30);
    } else if (rune >= 0x30 && rune <= 0x39) {
      buffer.writeCharCode(rune);
    }
  }
  final digits = buffer.toString();
  return digits.isEmpty ? null : int.tryParse(digits);
}

int? _credit(String html) {
  final label = _label(html, 'lblCredit');
  if (label == null) return null;
  return _price(label);
}

String _text(String html) => html
    .replaceAll(RegExp(r'<[^>]*>'), ' ')
    .replaceAll('&nbsp;', ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String _attr(String tag, String name) {
  final m = RegExp('${RegExp.escape(name)}\\s*=\\s*"([^"]*)"').firstMatch(tag);
  return m?.group(1) ?? '';
}

String _input(String html, String id) {
  final m = RegExp('id="' + RegExp.escape(id) + r'"[^>]*value="([^"]*)"')
      .firstMatch(html);
  return m?.group(1) ?? '';
}

String _value(String html, String id) {
  final m = RegExp('id="[^"]*' + RegExp.escape(id) + r'"[^>]*value="([^"]*)"')
      .firstMatch(html);
  if (m != null) return m.group(1)!;
  final inner = RegExp('id="[^"]*' + RegExp.escape(id) + r'"[^>]*>([^<]*)<')
      .firstMatch(html);
  return inner?.group(1)?.trim() ?? '';
}

String? _label(String html, String id) {
  final m = RegExp('<label[^>]*id="' + RegExp.escape(id) + r'"[^>]*>(.*?)</label>',
          dotAll: true)
      .firstMatch(html);
  final t = m?.group(1)?.replaceAll(RegExp(r'\s+'), ' ').trim();
  return (t == null || t.isEmpty) ? null : t;
}

String? _textById(String html, String id) {
  final m = RegExp('id="[^"]*' + RegExp.escape(id) + r'"[^>]*>(.*?)<', dotAll: true)
      .firstMatch(html);
  final t = m?.group(1)?.replaceAll(RegExp(r'\s+'), ' ').trim();
  return (t == null || t.isEmpty) ? null : t;
}
