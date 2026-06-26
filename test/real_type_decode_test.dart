import 'dart:typed_data';

import 'package:dpgsql/dpgsql.dart';
import 'package:test/test.dart';

import 'test_config.dart';

void main() {
  test('real connection decodes common PostgreSQL scalar and array types',
      () async {
    final conn = await openRealConnectionOrSkip();
    if (conn == null) return;

    final reader = await conn.createCommand('''
SELECT
  '-2147483648'::int4,
  '9223372036854775807'::int8,
  true::bool,
  10.25::float8,
  'driver text'::text,
  decode('00ff', 'hex'),
  ARRAY[1,2,3]::int4[],
  123.45::numeric,
  '[1,10)'::int4range,
  '[,5]'::int4range
''').executeReader();

    try {
      expect(await reader.read(), isTrue);
      expect(reader.getValue(0), equals(-2147483648));
      expect(reader.getValue(1), equals(9223372036854775807));
      expect(reader.getValue(2), isTrue);
      expect(reader.getValue(3), equals(10.25));
      expect(reader.getValue(4), equals('driver text'));

      final bytea = reader.getValue(5);
      expect(bytea, isA<Uint8List>());
      expect(bytea, orderedEquals(<int>[0, 255]));

      final array = reader.getValue(6);
      if (array is List) {
        expect(array, orderedEquals(<int>[1, 2, 3]));
      } else {
        expect(array.toString(), anyOf('{1,2,3}', '[1, 2, 3]'));
      }

      expect(reader.getValue(7).toString(), equals('123.45'));
      expect(
        reader.getValue(8),
        const DpgsqlRange<int>(lowerBound: 1, upperBound: 10),
      );
      expect(reader.getValue(9).toString(), equals('(,6)'));
      expect(await reader.read(), isFalse);
    } finally {
      await reader.close();
      await conn.close();
    }
  });
}
