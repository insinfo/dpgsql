// Text date/timestamp/timestamptz values are read digit by digit (the
// DateStyle ISO forms) and give the same DateTime as DateTime.parse.

import 'package:dpgsql/src/internal/timezone_helper.dart';
import 'package:dpgsql/src/timezone_settings.dart';
import 'package:test/test.dart';

void main() {
  const utc = TimeZoneSettings.utc();

  test('timestamp text', () {
    for (final (text, expected) in [
      ('2024-03-10 12:34:56', DateTime.utc(2024, 3, 10, 12, 34, 56)),
      ('2024-03-10 12:34:56.5', DateTime.utc(2024, 3, 10, 12, 34, 56, 500)),
      (
        '2024-03-10 12:34:56.789123',
        DateTime.utc(2024, 3, 10, 12, 34, 56, 789, 123)
      ),
      ('2024-03-10 00:00:00.000001', DateTime.utc(2024, 3, 10, 0, 0, 0, 0, 1)),
      ('0001-01-01 00:00:00', DateTime.utc(1, 1, 1)),
      (
        '9999-12-31 23:59:59.999999',
        DateTime.utc(9999, 12, 31, 23, 59, 59, 999, 999)
      ),
      // Fallback: BC and years after 9999.
      ('0044-03-15 10:00:00 BC', DateTime.utc(-43, 3, 15, 10)),
      ('10000-01-01 00:00:00', DateTime.utc(10000)),
    ]) {
      expect(TimezoneHelper.decodeTimestampText(text, timeZone: utc), expected,
          reason: text);
    }
  });

  test('timestamptz text with offsets', () {
    for (final (text, expected) in [
      ('2024-03-10 12:34:56+00', DateTime.utc(2024, 3, 10, 12, 34, 56)),
      ('2024-03-10 12:34:56-03', DateTime.utc(2024, 3, 10, 15, 34, 56)),
      (
        '2024-03-10 12:34:56.25+05:30',
        DateTime.utc(2024, 3, 10, 7, 4, 56, 250)
      ),
      ('1900-01-01 00:00:00-03:06:28', DateTime.utc(1900, 1, 1, 3, 6, 28)),
    ]) {
      expect(
          TimezoneHelper.decodeTimestampTzText(text, timeZone: utc), expected,
          reason: text);
    }
  });

  test('date text', () {
    expect(TimezoneHelper.decodeDateText('2024-03-10', timeZone: utc),
        DateTime.utc(2024, 3, 10));
    expect(TimezoneHelper.decodeDateText('0044-03-15 BC', timeZone: utc),
        DateTime.utc(-43, 3, 15));
  });
}
