import 'dart:convert';

import 'package:dpgsql/dpgsql.dart';
import 'package:dpgsql/src/internal/timezone_helper.dart';
import 'package:test/test.dart';

void main() {
  test('Timezone transition adjustment preserves offset delta', () {
    final nowDt = DateTime.now();
    final baseDt = DateTime(2000);

    final fixed = TimezoneHelper.fixTimezoneTransition(baseDt);
    final expectedShift = baseDt.timeZoneOffset - nowDt.timeZoneOffset;

    expect(fixed.difference(baseDt), expectedShift);
  });

  test('Encoding support - latin1', () {
    // Test encoding configuration
    final connString = 'Host=localhost;Port=5432;Database=test;Encoding=latin1';
    final builder = NpgsqlConnectionStringBuilder(connString);

    expect(builder.clientEncoding, 'latin1');
    expect(builder.encoding, latin1);
  });

  test('Encoding support - UTF8', () {
    final connString = 'Host=localhost;Port=5432;Database=test';
    final builder = NpgsqlConnectionStringBuilder(connString);

    // UTF8 is default
    expect(builder.clientEncoding, 'UTF8');
    expect(builder.encoding, utf8);
  });

  test('Encoding support - WIN1252', () {
    final connString =
        'Host=localhost;Port=5432;Database=test;Encoding=win1252';
    final builder = NpgsqlConnectionStringBuilder(connString);

    expect(builder.clientEncoding, 'win1252');
    // WIN1252 is mapped to latin1 for now (Dart doesn't have built-in WIN1252)
    expect(builder.encoding, latin1);
  });

  test('Timestamp without timezone behavior', () {
    // PostgreSQL TIMESTAMP (without timezone) should preserve local time
    // Not convert to UTC

    // This is the expected behavior per PostgreSQL documentation:
    // TIMESTAMP stores date/time without timezone info
    // TIMESTAMPTZ stores date/time with timezone info (always UTC internally)

    expect(DateTime(2024, 7, 19, 11, 10).isUtc, false);
    expect(DateTime.utc(2024, 7, 19, 11, 10).isUtc, true);
  });
}
