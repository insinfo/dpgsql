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
    expect(DateTime(2024, 7, 19, 11, 10).isUtc, false);
    expect(DateTime.utc(2024, 7, 19, 11, 10).isUtc, true);
  });

  test('TimeZoneSettings defaults match postgres/postgresql-fork UTC decode',
      () {
    final builder = DpgsqlConnectionStringBuilder('Host=localhost');
    final settings = builder.timeZone;

    expect(settings.value, 'UTC');
    expect(settings.forceDecodeDateAsUTC, isTrue);
    expect(settings.forceDecodeTimestampAsUTC, isTrue);
    expect(settings.forceDecodeTimestamptzAsUTC, isTrue);
    expect(settings.useCurrentOffsetForLocalTimestamp, isTrue);

    final decoded = TimezoneHelper.decodeTimestamp(
      0,
      timeZone: settings,
    );
    expect(decoded, DateTime.utc(2000));
    expect(decoded!.isUtc, isTrue);
  });

  test('TimeZoneSettings can decode timestamp as local without correction', () {
    final builder = DpgsqlConnectionStringBuilder(
      'Host=localhost;TimeZone=America/Sao_Paulo;'
      'Force Decode Timestamp As UTC=false;'
      'Force Decode Date As UTC=false;'
      'Force Decode Timestamptz As UTC=false;'
      'Use Current Offset For Local Timestamp=false',
    );
    final settings = builder.timeZone;

    expect(settings.value, 'America/Sao_Paulo');
    expect(settings.forceDecodeDateAsUTC, isFalse);
    expect(settings.forceDecodeTimestampAsUTC, isFalse);
    expect(settings.forceDecodeTimestamptzAsUTC, isFalse);
    expect(settings.useCurrentOffsetForLocalTimestamp, isFalse);

    final decoded = TimezoneHelper.decodeTimestamp(
      0,
      timeZone: settings,
    );
    expect(decoded, DateTime(2000));
    expect(decoded!.isUtc, isFalse);
  });

  test('TimeZoneSettings decodes timestamptz with named IANA timezone', () {
    final settings = const TimeZoneSettings(
      'America/Sao_Paulo',
      forceDecodeTimestamptzAsUTC: false,
      useIanaTimeZoneDatabase: true,
    );

    final july2000Micros =
        DateTime.utc(2000, 7, 1).difference(DateTime.utc(2000)).inMicroseconds;
    final decoded = TimezoneHelper.decodeTimestampTz(
      july2000Micros,
      timeZone: settings,
    );

    expect(decoded!.isUtc, isFalse);
    expect(decoded.year, 2000);
    expect(decoded.month, 6);
    expect(decoded.day, 30);
    expect(decoded.hour, 21);
    expect(decoded.timeZoneOffset, const Duration(hours: -3));
  });

  test('TimeZoneSettings can use IANA instant conversion for timestamptz', () {
    final settings = const TimeZoneSettings(
      'America/Sao_Paulo',
      forceDecodeTimestamptzAsUTC: false,
      useCurrentOffsetForLocalTimestamp: false,
      useIanaTimeZoneDatabase: true,
    );

    final decoded = TimezoneHelper.decodeTimestampTz(
      0,
      timeZone: settings,
    );

    expect(decoded!.isUtc, isFalse);
    expect(decoded.year, 1999);
    expect(decoded.month, 12);
    expect(decoded.day, 31);
    expect(decoded.hour, 22);
    expect(decoded.timeZoneOffset, const Duration(hours: -2));
    expect(decoded.isAtSameMomentAs(DateTime.utc(2000)), isTrue);
  });

  test('TimeZoneSettings does not resolve IANA database unless enabled', () {
    final settings = const TimeZoneSettings(
      'Invalid/Zone',
      forceDecodeTimestamptzAsUTC: false,
    );

    expect(
      () => TimezoneHelper.decodeTimestampTz(0, timeZone: settings),
      returnsNormally,
    );
  });

  test('TimeZoneSettings decodes date/time infinity as null by default', () {
    final settings = DpgsqlConnectionStringBuilder('Host=localhost').timeZone;

    expect(settings.throwOnDateTimeInfinity, isFalse);
    expect(TimezoneHelper.decodeDate(2147483647, timeZone: settings), isNull);
    expect(TimezoneHelper.decodeDate(-2147483648, timeZone: settings), isNull);
    expect(
      TimezoneHelper.decodeTimestamp(9223372036854775807, timeZone: settings),
      isNull,
    );
    expect(
      TimezoneHelper.decodeTimestampTz(
        -9223372036854775808,
        timeZone: settings,
      ),
      isNull,
    );
    expect(
        TimezoneHelper.decodeDateText('infinity', timeZone: settings), isNull);
    expect(TimezoneHelper.decodeTimestampText('-infinity', timeZone: settings),
        isNull);
  });

  test('TimeZoneSettings can throw on date/time infinity when configured', () {
    final settings = DpgsqlConnectionStringBuilder(
      'Host=localhost;Throw On DateTime Infinity=true',
    ).timeZone;

    expect(settings.throwOnDateTimeInfinity, isTrue);
    expect(
      () => TimezoneHelper.decodeTimestamp(
        9223372036854775807,
        timeZone: settings,
      ),
      throwsArgumentError,
    );
    expect(
      () => TimezoneHelper.decodeDateText('infinity', timeZone: settings),
      throwsArgumentError,
    );
  });
}
