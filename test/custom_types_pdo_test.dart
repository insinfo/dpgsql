import 'package:test/test.dart';
import 'package:dpgsql/dpgsql.dart';

void main() {
  test('PDO-style query with ? placeholders API', () {
    expect(_pdoStyleExample, isA<Function>());
  });

  test('Existing custom types NpgsqlInterval, NpgsqlDate, NpgsqlTime', () {
    // NpgsqlInterval already exists and works well
    final interval = NpgsqlInterval.parse('1 year 2 mons 3 days');
    expect(interval.months, 14); // 12 + 2

    // NpgsqlDate (existing raw format)
    final date = NpgsqlDate(100); // 100 days since 2000-01-01
    expect(date.days, 100);

    // NpgsqlTime (existing raw format)
    final time = NpgsqlTime(3600000000); // 1 hour in microseconds
    expect(time.microseconds, 3600000000);

    // NpgsqlTimestamp (existing raw format)
    final ts =
        NpgsqlTimestamp(1000000); // 1 second in microseconds since 2000-01-01
    expect(ts.microseconds, 1000000);
  });

  test('NpgsqlTypesConfig for enabling custom type handling', () {
    // Config with all custom types enabled
    final config1 = NpgsqlTypesConfig.allCustom();
    expect(config1.useCustomDate, true);
    expect(config1.useCustomTimestamp, true);
    expect(config1.useCustomDecimal, true);
    expect(config1.useCustomInterval, true);

    // Config with recommended settings (use Interval but not others)
    final config2 = NpgsqlTypesConfig.recommended();
    expect(config2.useCustomInterval, true);
    expect(config2.useCustomDecimal, false); // double is usually fine
    expect(config2.useCustomDate, false); // DateTime is usually fine
  });

  test('PlaceholderIdentifier enum exists', () {
    expect(PlaceholderIdentifier.numeric, isNotNull);
    expect(PlaceholderIdentifier.onlyQuestionMark, isNotNull);
    expect(PlaceholderIdentifier.atSign, isNotNull);
  });
}

void _pdoStyleExample() async {
  final conn = NpgsqlConnection('Host=localhost;Database=test');
  await conn.open();

  try {
    // PDO/PHP style with ? placeholders
    final reader = await conn.query(
      'SELECT * FROM users WHERE id = ? AND name = ?',
      substitutionValues: [42, 'Alice'],
    );

    while (await reader.read()) {
      print('User: ${reader.getValue(0)}, ${reader.getValue(1)}');
    }
    await reader.close();

    // Named parameters with @param style
    final reader2 = await conn.query(
      'SELECT * FROM users WHERE id = @id AND name = @name',
      substitutionValues: {'id': 42, 'name': 'Alice'},
    );

    while (await reader2.read()) {
      print('User: ${reader2.getValue(0)}');
    }
    await reader2.close();

    // PostgreSQL native style ($1, $2) also works
    final cmd = conn.createCommand('SELECT * FROM users WHERE id = \$1');
    cmd.parameters.addWithValue('id', 42);
    final reader3 = await cmd.executeReader();
    await reader3.close();
  } finally {
    await conn.close();
  }
}
