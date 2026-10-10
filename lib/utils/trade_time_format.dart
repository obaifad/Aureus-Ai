import 'package:intl/intl.dart';

/// Trade timestamps shown on the cards: a numeric date plus the English weekday, whatever the
/// device language is (`en_US` is bundled with intl, so no locale initialisation is needed).
class TradeTimeFormat {
  TradeTimeFormat._();

  static final DateFormat _date = DateFormat('dd.MM.yyyy', 'en_US');
  static final DateFormat _weekday = DateFormat('EEEE', 'en_US');
  static final DateFormat _time = DateFormat('HH:mm', 'en_US');

  /// `02.10.2026 - Friday`
  static String dateWithWeekday(DateTime t) {
    final local = t.toLocal();
    return '${_date.format(local)} - ${_weekday.format(local)}';
  }

  /// `02.10.2026 - Friday | 17:31` (card header).
  static String header(DateTime t) => '${dateWithWeekday(t)} | ${_time.format(t.toLocal())}';

  /// `02.10.2026 - Friday 17:57` (exit line).
  static String exitStamp(DateTime t) => '${dateWithWeekday(t)} ${_time.format(t.toLocal())}';
}
