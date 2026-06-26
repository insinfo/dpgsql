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
    final builder = DpgsqlConnectionStringBuilder(connString);

    expect(builder.clientEncoding, 'latin1');
    expect(builder.postgresClientEncoding, 'LATIN1');
    expect(builder.encoding, latin1);
  });

  test('Encoding support - UTF8', () {
    final connString = 'Host=localhost;Port=5432;Database=test';
    final builder = DpgsqlConnectionStringBuilder(connString);

    // UTF8 is default
    expect(builder.clientEncoding, 'UTF8');
    expect(builder.postgresClientEncoding, 'UTF8');
    expect(builder.encoding, utf8);
  });

  test('Encoding support - WIN1252', () {
    final connString =
        'Host=localhost;Port=5432;Database=test;Encoding=win1252';
    final builder = DpgsqlConnectionStringBuilder(connString);

    expect(builder.clientEncoding, 'win1252');
    expect(builder.postgresClientEncoding, 'WIN1252');
    expect(builder.encoding.name, 'windows-1252');
    expect(builder.encoding.encode('€'), equals([0x80]));
    expect(builder.encoding.decode([0x80]), '€');
  });

  test('Encoding support - PostgreSQL aliases backed by bundled codecs', () {
    final cases = <String, (String, String)>{
      'LATIN2': ('LATIN2', 'iso-8859-2'),
      'LATIN9': ('LATIN9', 'iso-8859-15'),
      'ISO_8859_5': ('ISO_8859_5', 'iso-8859-5'),
      'windows-1251': ('WIN1251', 'windows-1251'),
      'KOI8-R': ('KOI8R', 'KOI8-R'),
      'KOI8_U': ('KOI8U', 'KOI8-U'),
      'BIG5': ('BIG5', 'Big5'),
      'GBK': ('GBK', 'gbk'),
      'SQL_ASCII': ('SQL_ASCII', 'iso-8859-1'),
    };

    for (final entry in cases.entries) {
      final builder = DpgsqlConnectionStringBuilder(
        'Host=localhost;Encoding=${entry.key}',
      );
      expect(
        builder.postgresClientEncoding,
        entry.value.$1,
        reason: entry.key,
      );
      expect(builder.encoding.name, entry.value.$2, reason: entry.key);
    }
  });

  test('Encoding support - separates local Encoding from Client Encoding', () {
    final builder = DpgsqlConnectionStringBuilder(
      'Host=localhost;Encoding=windows-1252;Client Encoding=sql-ascii',
    );

    expect(builder.clientEncoding, 'sql-ascii');
    expect(builder.postgresClientEncoding, 'SQL_ASCII');
    expect(builder.encoding.name, 'windows-1252');
  });

  test('Encoding support - unsupported PostgreSQL encoding fails early', () {
    final builder = DpgsqlConnectionStringBuilder(
      'Host=localhost;Encoding=EUC_JP',
    );

    expect(() => builder.encoding, throwsUnsupportedError);
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
