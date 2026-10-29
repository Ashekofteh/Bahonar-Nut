import 'package:bahonar_nut/core/platform_stores.dart';
import 'package:bahonar_nut/ui/reservation_table_model.dart';
import 'package:bahonar_nut/core/time.dart';

void main() {
  const jsonStr = r'''[{"accountId":"acc-1792795066195221-2","date":"2026-10-26T00:00:00.000Z","slot":"breakfast","source":"weeklyReservation","capturedAt":"2026-10-23T22:37:58.937618Z","optionId":"63059","dishName":"کره/مربا/شیرطعم دار/نان/چای/قند","hallName":"مرکزی برادران","priceRial":150000},{"accountId":"acc-1792795066195221-2","date":"2026-10-25T00:00:00.000Z","slot":"lunch","source":"weeklyReservation","capturedAt":"2026-10-23T22:37:58.937774Z","optionId":"63049","dishName":"شوید پلو با تن ماهی,لیمو ترش, دلستر","hallName":"مرکزی برادران","priceRial":500000}]''';

  final meals = decodeMealList(jsonStr);
  print('Decoded meals count: ${meals.length}');
  for (final m in meals) {
    print('Meal: ${m.date} - ${m.slot} - ${m.dishName}');
  }

  final rows = buildMealRows(menus: [], held: meals, clock: null);
  print('Rows count: ${rows.length}');

  // Current Saturday according to Oct 24, 2026
  final sat = weekStartSaturday(DateTime.utc(2026, 10, 24));
  print('Saturday: $sat');
  final filtered = filterRowsForWeek(rows, sat);
  print('Filtered count: ${filtered.length}');
  for (final r in filtered) {
    print('Row: ${r.date} - ${r.slot} - ${r.dishName} - ${r.statusLabel}');
  }
}
