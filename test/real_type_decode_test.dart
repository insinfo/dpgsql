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
  '[,5]'::int4range,
  '2024-01-02 03:04:05'::timestamp,
  NULL::text
''').executeReader();

    try {
      expect(await reader.read(), isTrue);
      expect(reader.getValue(0), equals(-2147483648));
      expect(reader.getInt(0), equals(-2147483648));
      expect(reader.getValue(1), equals(9223372036854775807));
      expect(reader.getValue(2), isTrue);
      expect(reader.getBool(2), isTrue);
      expect(reader.getValue(3), equals(10.25));
      expect(reader.getDouble(3), equals(10.25));
      expect(reader.getValue(4), equals('driver text'));
      expect(reader.getString(4), equals('driver text'));

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
      expect(reader.getDouble(7), equals(123.45));
      expect(
        reader.getValue(8),
        const DpgsqlRange<int>(lowerBound: 1, upperBound: 10),
      );
      expect(reader.getValue(9).toString(), equals('(,6)'));
      final timestamp = reader.getDateTime(10);
      expect(timestamp.year, equals(2024));
      expect(timestamp.month, equals(1));
      expect(timestamp.day, equals(2));
      expect(reader.isDBNull(11), isTrue);
      expect(await reader.read(), isFalse);
    } finally {
      await reader.close();
      await conn.close();
    }
  });

  test('real connection decodes uuid, bit and varbit types', () async {
    final conn = await openRealConnectionOrSkip();
    if (conn == null) return;

    try {
      final reader = await conn.createCommand('''
SELECT
  '00112233-4455-6677-8899-aabbccddeeff'::uuid,
  B'1010'::bit(4),
  B'101100001'::varbit
''').executeReader();

      try {
        expect(await reader.read(), isTrue);
        expect(reader.getValue(0),
            DpgsqlUuid.parse('00112233-4455-6677-8899-aabbccddeeff'));
        expect(reader.getValue(1), DpgsqlBitString('1010'));
        expect(reader.getValue(2), DpgsqlBitString('101100001'));
        expect(await reader.read(), isFalse);
      } finally {
        await reader.close();
      }

      final command = conn.createCommand('''
SELECT
  @uuid_value::uuid,
  @bit_value::bit(4),
  @varbit_value::varbit
''');
      command.parameters.add(
          DpgsqlParameter('uuid_value', '00112233-4455-6677-8899-aabbccddeeff')
            ..dpgsqlDbType = DpgsqlDbType.uuid);
      command.parameters.add(DpgsqlParameter('bit_value', '0101')
        ..dpgsqlDbType = DpgsqlDbType.bit);
      command.parameters.add(
          DpgsqlParameter('varbit_value', DpgsqlBitString('111000'))
            ..dpgsqlDbType = DpgsqlDbType.varbit);

      final rows = await command.executeRows();
      expect(rows.single[0],
          DpgsqlUuid.parse('00112233-4455-6677-8899-aabbccddeeff'));
      expect(rows.single[1], DpgsqlBitString('0101'));
      expect(rows.single[2], DpgsqlBitString('111000'));
    } finally {
      await conn.close();
    }
  });

  test('real connection decodes inet, cidr and macaddr types', () async {
    final conn = await openRealConnectionOrSkip(
      options: 'Decode Network Types As String=false',
    );
    if (conn == null) return;

    try {
      final reader = await conn.createCommand('''
SELECT
  '192.168.10.5'::inet,
  '10.0.0.0/8'::cidr,
  '08:00:2b:01:02:03'::macaddr
''').executeReader();

      try {
        expect(await reader.read(), isTrue);
        expect(reader.getValue(0), DpgsqlInet.parse('192.168.10.5'));
        expect(reader.getValue(1), DpgsqlCidr.parse('10.0.0.0/8'));
        expect(
          reader.getValue(2),
          DpgsqlMacAddress.parse('08:00:2b:01:02:03'),
        );
        expect(await reader.read(), isFalse);
      } finally {
        await reader.close();
      }

      final command = conn.createCommand('''
SELECT
  @ip_value::inet,
  @network_value::cidr,
  @mac_value::macaddr
''');
      command.parameters.add(DpgsqlParameter('ip_value', '172.16.1.20')
        ..dpgsqlDbType = DpgsqlDbType.inet);
      command.parameters.add(
        DpgsqlParameter('network_value', DpgsqlCidr.parse('172.16.0.0/12'))
          ..dpgsqlDbType = DpgsqlDbType.cidr,
      );
      command.parameters.add(
        DpgsqlParameter('mac_value', DpgsqlMacAddress.parse('08002b010203'))
          ..dpgsqlDbType = DpgsqlDbType.macaddr,
      );

      final rows = await command.executeRows();
      expect(rows.single[0], DpgsqlInet.parse('172.16.1.20'));
      expect(rows.single[1], DpgsqlCidr.parse('172.16.0.0/12'));
      expect(rows.single[2], DpgsqlMacAddress.parse('08:00:2b:01:02:03'));
    } finally {
      await conn.close();
    }
  });

  test('network types can be decoded as strings for ORM compatibility',
      () async {
    final conn = await openRealConnectionOrSkip();
    if (conn == null) return;

    try {
      final rows = await conn.executeMaps('''
SELECT
  '192.168.10.5'::inet AS ip,
  '10.0.0.0/8'::cidr AS network,
  '08:00:2b:01:02:03'::macaddr AS mac
''');

      expect(rows.single['ip'], '192.168.10.5');
      expect(rows.single['network'], '10.0.0.0/8');
      expect(rows.single['mac'], '08:00:2b:01:02:03');
    } finally {
      await conn.close();
    }
  });

  test('executeRows materializes decoded result sets', () async {
    final conn = await openRealConnectionOrSkip();
    if (conn == null) return;

    final command = conn.createCommand('''
SELECT
  42::int4,
  'materialized'::text,
  10.50::numeric,
  '2024-01-02 03:04:05'::timestamp
''');

    try {
      final rows = await command.executeRows();
      expect(rows, hasLength(1));
      expect(rows.first[0], equals(42));
      expect(rows.first[1], equals('materialized'));
      expect(rows.first[2], equals(10.5));
      expect(rows.first[3], isA<DateTime>());
    } finally {
      await conn.close();
    }
  });

  test('executeScalar returns first column and supports prepared commands',
      () async {
    final conn = await openRealConnectionOrSkip();
    if (conn == null) return;

    try {
      expect(await conn.executeScalar('SELECT 42::int'), equals(42));
      expect(await conn.executeScalar('SELECT NULL::text'), isNull);

      final command = conn.createCommand('SELECT @value::int + 1');
      command.parameters.addWithValue('value', 10);
      await command.prepare();

      expect(await command.executeScalar(), equals(11));
      command.parameters[0].value = 20;
      expect(await command.executeScalar(), equals(21));
    } finally {
      await conn.close();
    }
  });

  test('executeMaps materializes decoded maps for ORM-style rows', () async {
    final conn = await openRealConnectionOrSkip();
    if (conn == null) return;

    try {
      final rows = await conn.executeMaps('''
SELECT
  42::int4 AS id,
  'sali'::text AS nome,
  true::bool AS ativo,
  10.50::numeric AS valor,
  '2024-01-02 03:04:05'::timestamp AS criado_em
''');

      expect(rows, hasLength(1));
      expect(rows.first['id'], equals(42));
      expect(rows.first['nome'], equals('sali'));
      expect(rows.first['ativo'], isTrue);
      expect(rows.first['valor'], equals(10.5));
      expect(rows.first['criado_em'], isA<DateTime>());
    } finally {
      await conn.close();
    }
  });

  test('rawText result mode materializes PHP-style string maps', () async {
    final conn = await openRealConnectionOrSkip();
    if (conn == null) return;

    try {
      final rows = await conn.executeMaps(
        '''
SELECT
  42::int4 AS id,
  true::bool AS ativo,
  10.50::numeric AS valor,
  '2024-01-02 03:04:05'::timestamp AS criado_em,
  '{"a":1}'::jsonb AS payload,
  NULL::text AS nulo
''',
        resultMode: PgResultMode.rawText,
      );

      expect(rows, hasLength(1));
      expect(rows.first['id'], equals('42'));
      expect(rows.first['ativo'], equals('t'));
      expect(rows.first['valor'], equals('10.50'));
      expect(rows.first['criado_em'], startsWith('2024-01-02 03:04:05'));
      expect(rows.first['payload'], anyOf('{"a": 1}', '{"a":1}'));
      expect(rows.first['nulo'], isNull);
    } finally {
      await conn.close();
    }
  });

  test('rawText result mode works with prepared parameterized commands',
      () async {
    final conn = await openRealConnectionOrSkip();
    if (conn == null) return;

    final command = conn.createCommand('''
SELECT @id::int4 AS id, @ativo::bool AS ativo, NULL::text AS nulo
''');
    command.parameters.addWithValue('id', 123);
    command.parameters.addWithValue('ativo', true);

    try {
      await command.prepare();
      final rows = await command.executeMaps(resultMode: PgResultMode.rawText);
      expect(
        rows.single,
        equals(<String, dynamic>{
          'id': '123',
          'ativo': 't',
          'nulo': null,
        }),
      );
    } finally {
      await conn.close();
    }
  });

  test('date/time infinity materializes as null by default', () async {
    final conn = await openRealConnectionOrSkip();
    if (conn == null) return;

    try {
      final simpleRows = await conn.executeMaps('''
SELECT
  'infinity'::date AS d,
  '-infinity'::timestamp AS ts,
  'infinity'::timestamptz AS tstz
''');
      expect(simpleRows.single['d'], isNull);
      expect(simpleRows.single['ts'], isNull);
      expect(simpleRows.single['tstz'], isNull);

      final command = conn.createCommand('''
SELECT
  'infinity'::date AS d,
  '-infinity'::timestamp AS ts,
  'infinity'::timestamptz AS tstz,
  @id::int4 AS id
''');
      command.parameters.addWithValue('id', 1);
      await command.prepare();
      final preparedRows = await command.executeMaps();
      expect(preparedRows.single['d'], isNull);
      expect(preparedRows.single['ts'], isNull);
      expect(preparedRows.single['tstz'], isNull);
      expect(preparedRows.single['id'], 1);
    } finally {
      await conn.close();
    }
  });

  test('prepared executeMaps uses cached row description', () async {
    final conn = await openRealConnectionOrSkip();
    if (conn == null) return;

    final command = conn.createCommand('''
SELECT @id::int4 AS id, @nome::text AS nome
''');
    command.parameters.addWithValue('id', 7);
    command.parameters.addWithValue('nome', 'processo');

    try {
      await command.prepare();
      var rows = await command.executeMaps();
      expect(
          rows.single,
          equals(<String, dynamic>{
            'id': 7,
            'nome': 'processo',
          }));

      command.parameters[0].value = 8;
      command.parameters[1].value = 'andamento';
      rows = await command.executeMaps();
      expect(
          rows.single,
          equals(<String, dynamic>{
            'id': 8,
            'nome': 'andamento',
          }));
    } finally {
      await conn.close();
    }
  });

  test('reader toMap and readAllMaps expose decoded maps', () async {
    final conn = await openRealConnectionOrSkip();
    if (conn == null) return;

    try {
      final reader = await conn.createCommand('''
SELECT i::int4 AS id, ('row_' || i)::text AS nome
FROM generate_series(1, 3) AS s(i)
ORDER BY i
''').executeReader();

      expect(await reader.read(), isTrue);
      expect(
          reader.toMap(),
          equals(<String, dynamic>{
            'id': 1,
            'nome': 'row_1',
          }));

      final remaining = await reader.readAllMaps();
      expect(
          remaining,
          equals(<Map<String, dynamic>>[
            {'id': 2, 'nome': 'row_2'},
            {'id': 3, 'nome': 'row_3'},
          ]));
      await reader.close();
    } finally {
      await conn.close();
    }
  });

  test('executePgRows materializes lazy row views', () async {
    final conn = await openRealConnectionOrSkip();
    if (conn == null) return;

    final command = conn.createCommand('''
SELECT 7::int4 AS id, 'lazy text'::text AS name
''');

    try {
      await command.prepare();
      final rows = await command.executePgRows();
      expect(rows, hasLength(1));
      expect(rows.first.getInt(0), equals(7));
      expect(rows.first.getString(1), equals('lazy text'));
      expect(rows.first.columnNames, containsAll(<String>['id', 'name']));
    } finally {
      await conn.close();
    }
  });

  test('forEachPgRow streams transient lazy row views', () async {
    final conn = await openRealConnectionOrSkip();
    if (conn == null) return;

    final command = conn.createCommand('''
SELECT i::int4 AS id, 'row_' || i::text AS name
FROM generate_series(1, 5) AS s(i)
ORDER BY i
''');

    try {
      await command.prepare();
      var checksum = 0;
      final names = <String>[];
      await command.forEachPgRow((row) {
        checksum += row.getInt(0)!;
        names.add(row.getString(1)!);
        expect(row.columnNames, containsAll(<String>['id', 'name']));
      });

      expect(checksum, equals(15));
      expect(
          names,
          orderedEquals(<String>[
            'row_1',
            'row_2',
            'row_3',
            'row_4',
            'row_5',
          ]));
    } finally {
      await conn.close();
    }
  });

  test('forEachPgRowSync streams transient lazy row views', () async {
    final conn = await openRealConnectionOrSkip();
    if (conn == null) return;

    final command = conn.createCommand('''
SELECT i::int4 AS id, 'sync_' || i::text AS name
FROM generate_series(1, 3) AS s(i)
ORDER BY i
''');

    try {
      await command.prepare();
      var checksum = 0;
      final names = <String>[];
      await command.forEachPgRowSync((row) {
        checksum += row.getInt(0)!;
        names.add(row.getString(1)!);
      });

      expect(checksum, equals(6));
      expect(names, orderedEquals(<String>['sync_1', 'sync_2', 'sync_3']));
    } finally {
      await conn.close();
    }
  });

  test('PgRow decodes numeric and timestamp on demand', () async {
    final conn = await openRealConnectionOrSkip();
    if (conn == null) return;

    final command = conn.createCommand('''
SELECT 123.45::numeric AS amount,
       '2024-01-02 03:04:05'::timestamp AS created_at
''');

    try {
      await command.prepare();
      final rows = await command.executePgRows();
      expect(rows, hasLength(1));
      expect(rows.first.getNumericDouble(0), equals(123.45));
      final timestamp = rows.first.getDateTime(1)!;
      expect(timestamp.year, equals(2024));
      expect(timestamp.month, equals(1));
      expect(timestamp.day, equals(2));
      expect(timestamp.hour, equals(3));
      expect(timestamp.minute, equals(4));
      expect(timestamp.second, equals(5));
    } finally {
      await conn.close();
    }
  });

  test('real timestamp decode follows connection TimeZoneSettings', () async {
    final utcConn = await openRealConnectionOrSkip();
    if (utcConn == null) return;

    final localConn = await openRealConnectionOrSkip(
      options: 'Force Decode Timestamp As UTC=false;'
          'Use Current Offset For Local Timestamp=false',
    );
    if (localConn == null) {
      await utcConn.close();
      return;
    }

    try {
      final utcValue = await executeScalar(
        utcConn,
        "SELECT '2000-01-01 00:00:00'::timestamp",
      ) as DateTime;
      final localValue = await executeScalar(
        localConn,
        "SELECT '2000-01-01 00:00:00'::timestamp",
      ) as DateTime;

      expect(utcValue, DateTime.utc(2000));
      expect(utcValue.isUtc, isTrue);
      expect(localValue, DateTime(2000));
      expect(localValue.isUtc, isFalse);
    } finally {
      await utcConn.close();
      await localConn.close();
    }
  });

  test('real timestamptz decode follows named connection timezone', () async {
    final conn = await openRealConnectionOrSkip(
      options: 'TimeZone=America/Sao_Paulo;'
          'Force Decode Timestamptz As UTC=false;'
          'Use Current Offset For Local Timestamp=false;'
          'Use IANA Time Zone Database=true',
    );
    if (conn == null) return;

    try {
      final value = await executeScalar(
        conn,
        "SELECT '2024-07-01 00:00:00+00'::timestamptz",
      ) as DateTime;

      expect(value.isUtc, isFalse);
      expect(value.year, equals(2024));
      expect(value.month, equals(6));
      expect(value.day, equals(30));
      expect(value.hour, equals(21));
      expect(value.timeZoneOffset, equals(const Duration(hours: -3)));
      expect(value.isAtSameMomentAs(DateTime.utc(2024, 7, 1)), isTrue);
    } finally {
      await conn.close();
    }
  });
}
