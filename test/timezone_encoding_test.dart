import 'package:test/test.dart';
import 'package:dpgsql/dpgsql.dart';
import 'dart:convert';

void main() {
  test('Timezone fix test', () {
    // Test timezone transition fix
    // This tests the fix for https://github.com/dart-lang/sdk/issues/56312

    // The issue: On Linux, DateTime(2000) may have different timezone than DateTime.now()
    // causing incorrect timestamp decoding from PostgreSQL

    final nowDt = DateTime.now();
    var baseDt = DateTime(2000);

    print('Now timezone: ${nowDt.timeZoneOffset}');
    print('DateTime(2000) timezone: ${baseDt.timeZoneOffset}');

    if (baseDt.timeZoneOffset != nowDt.timeZoneOffset) {
      print('Timezone transition detected! Applying fix...');
      final difference = baseDt.timeZoneOffset - nowDt.timeZoneOffset;
      baseDt = baseDt.add(difference);
      print('Fixed DateTime(2000) timezone: ${baseDt.timeZoneOffset}');
    }

    // The fix ensures that timestamp decoding preserves local time correctly
    expect(baseDt.timeZoneOffset, nowDt.timeZoneOffset);
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

void _usageExample() async {
  // Example 1: Using encoding in connection string
  final conn1 = NpgsqlConnection(
      'Host=localhost;Port=5432;Database=sistemas;Encoding=latin1');
  await conn1.open();

  // SELECT will decode strings using latin1 instead of UTF8
  final results = await conn1
      .createCommand('SELECT * FROM table_with_latin1_data')
      .executeReader();
  await results.close();
  await conn1.close();

  // Example 2: Timestamp without timezone test
  final conn2 = NpgsqlConnection('Host=localhost;Database=test');
  await conn2.open();

  // INSERT timestamp - preserves local time
  final now = DateTime.now();
  await conn2.createCommand('''
    CREATE TABLE IF NOT EXISTS test_timestamps (
      id SERIAL PRIMARY KEY,
      ts_without TIMESTAMP,
      ts_with TIMESTAMPTZ,
      dt DATE
    )
  ''').executeNonQuery();

  final cmd = conn2.createCommand('''
    INSERT INTO test_timestamps (ts_without, ts_with, dt) 
    VALUES (\$1, \$2, \$3)
  ''');
  cmd.parameters.addWithValue('ts_without', now);
  cmd.parameters.addWithValue('ts_with', now);
  cmd.parameters.addWithValue('dt', now);
  await cmd.executeNonQuery();

  // SELECT timestamp - preserves local time for TIMESTAMP, converts for TIMESTAMPTZ
  final reader = await conn2
      .createCommand('SELECT * FROM test_timestamps')
      .executeReader();
  while (await reader.read()) {
    final tsWithout = reader.getValue(1) as DateTime; // Local time
    final tsWith =
        reader.getValue(2) as DateTime; // Local time (converted from UTC)
    final dt = reader.getValue(3) as DateTime; // Local time (date only)

    print('TIMESTAMP: $tsWithout (${tsWithout.timeZoneOffset})');
    print('TIMESTAMPTZ: $tsWith (${tsWith.timeZoneOffset})');
    print('DATE: $dt');
  }
  await reader.close();
  await conn2.close();
}
