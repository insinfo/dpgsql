// Type round trips against a real server, in the text format (simple
// protocol) and the binary format (extended protocol, parameters, prepared
// statements), through every read path: they decode values with different
// code (reader getValue, readAllMaps, executeRows, the prepared fast paths).

import 'dart:typed_data';

import 'package:dpgsql/dpgsql.dart';
import 'package:test/test.dart';

import 'test_config.dart';

const _paths = [
  'executeScalar',
  'executeMaps',
  'executeRows',
  'reader.getValue',
  'prepared executeMaps',
  'prepared executeRows',
  'prepared executeScalar',
];

DpgsqlParameterCollection? _params(List<Object?>? values) {
  if (values == null) return null;
  final parameters = DpgsqlParameterCollection();
  for (var i = 0; i < values.length; i++) {
    parameters.add(DpgsqlParameter('p$i', values[i]));
  }
  return parameters;
}

/// The value of the single column of [sql]'s single row, read by each of
/// [_paths].
Future<List<Object?>> _readEverywhere(DpgsqlConnection conn, String sql,
    [List<Object?>? values]) async {
  final read = <Object?>[];
  read.add(await conn.executeScalar(sql, parameters: _params(values)));
  read.add((await conn.executeMaps(sql, parameters: _params(values)))
      .single
      .values
      .single);
  read.add(
      (await conn.executeRows(sql, parameters: _params(values))).single.single);
  final reader = await conn.executeReader(sql, parameters: _params(values));
  try {
    expect(await reader.read(), isTrue);
    read.add(reader.getValue(0));
  } finally {
    await reader.close();
  }
  final cmd = conn.createCommand(sql);
  final parameters = _params(values);
  if (parameters != null) cmd.parameters.addAll(parameters);
  await cmd.prepare();
  read.add((await cmd.executeMaps()).single.values.single);
  read.add((await cmd.executeRows()).single.single);
  read.add(await cmd.executeScalar());
  return read;
}

void main() {
  late DpgsqlConnection text;
  late DpgsqlConnection binary;
  var available = true;

  setUpAll(() async {
    final opened = await openRealConnectionOrSkip();
    if (opened == null) {
      available = false;
      return;
    }
    text = opened;
    binary = (await openRealConnectionOrSkip(
        options: 'Use Extended Query For Unparameterized Commands=true'))!;
  });

  tearDownAll(() async {
    if (!available) return;
    await text.close();
    await binary.close();
  });

  /// `select <expr> as v` in the text and the binary format, on every path.
  Future<void> expectValue(String expr, Object? matcher) async {
    for (final (format, conn) in [('text', text), ('binary', binary)]) {
      final read = await _readEverywhere(conn, 'select $expr as v');
      for (var i = 0; i < read.length; i++) {
        expect(read[i], matcher, reason: '$expr, $format, ${_paths[i]}');
      }
    }
  }

  /// `select ?::<type> as v` with [value]: sent, then read on every path.
  Future<void> expectParameter(Object? value, String type, Object? matcher,
      {DpgsqlDbType? dbType}) async {
    for (final (format, conn) in [('text', text), ('binary', binary)]) {
      final parameter = DpgsqlParameter('p0', value)..dpgsqlDbType = dbType;
      final sql = 'select ?::$type as v';
      final read = <Object?>[
        await conn.executeScalar(sql,
            parameters: DpgsqlParameterCollection()..add(parameter)),
        (await conn.executeMaps(sql,
                parameters: DpgsqlParameterCollection()..add(parameter)))
            .single['v'],
      ];
      final cmd = conn.createCommand(sql)..parameters.add(parameter);
      await cmd.prepare();
      read
        ..add((await cmd.executeMaps()).single['v'])
        ..add(await cmd.executeScalar());
      for (final value in read) {
        expect(value, matcher, reason: '$value as $type ($format)');
      }
    }
  }

  test('integers at their limits', () async {
    if (!available) return;
    await expectValue('(-32768)::int2', -32768);
    await expectValue('32767::int2', 32767);
    await expectValue('(-2147483648)::int4', -2147483648);
    await expectValue('2147483647::int4', 2147483647);
    await expectValue('(-9223372036854775808)::int8', -9223372036854775808);
    await expectValue('9223372036854775807::int8', 9223372036854775807);
    await expectValue('4294967295::oid', 4294967295);
  });

  test('int parameters beyond int4 are sent as int8, not truncated', () async {
    if (!available) return;
    // They were encoded in 4 bytes: 2^31 came back as -2^31, 2^63-1 as -1.
    await expectParameter(9223372036854775807, 'int8', 9223372036854775807);
    await expectParameter(-9223372036854775808, 'int8', -9223372036854775808);
    await expectParameter(2147483648, 'int8', 2147483648);
    await expectParameter(2147483647, 'int4', 2147483647);
    await expectParameter(-2147483648, 'int4', -2147483648);
    expect(
        await text.executeScalar('select pg_typeof(?)::text',
            parameters: _params([1 << 40])),
        'bigint');
    expect(await text.executeScalar('select ?', parameters: _params([1 << 40])),
        1 << 40);
    expect(
        await text.executeScalar('select ?::int8[]',
            parameters: _params([
              [1, 1 << 40, null]
            ])),
        [1, 1 << 40, null]);
  });

  test('DpgsqlDbType bigint/smallint/integer encode their own size', () async {
    if (!available) return;
    await expectParameter(1 << 40, 'int8', 1 << 40,
        dbType: DpgsqlDbType.bigint);
    await expectParameter(-1000, 'int2', -1000, dbType: DpgsqlDbType.smallint);
    await expectParameter(7, 'int4', 7, dbType: DpgsqlDbType.integer);

    // Out of range for the declared type: an error before anything is
    // sent, and the connection keeps working.
    for (final (value, dbType) in [
      (1 << 40, DpgsqlDbType.integer),
      (40000, DpgsqlDbType.smallint),
    ]) {
      final parameter = DpgsqlParameter('p0', value)..dpgsqlDbType = dbType;
      await expectLater(
          text.executeScalar('select ?',
              parameters: DpgsqlParameterCollection()..add(parameter)),
          throwsArgumentError);
      expect(await text.executeScalar('select 11'), 11);
    }
  });

  test('numeric decodes as double, NaN and infinities included', () async {
    if (!available) return;
    await expectValue('123.45::numeric', 123.45);
    await expectValue('(-1.5)::numeric', -1.5);
    await expectValue('0.0001::numeric', 0.0001);
    await expectValue('0::numeric', 0.0);
    // Binary NaN and the infinities came back as 0.0 (the sign word was
    // read as a signed int16).
    await expectValue("'NaN'::numeric", isNaN);
    await expectValue("'Infinity'::numeric", double.infinity);
    await expectValue("'-Infinity'::numeric", double.negativeInfinity);
    await expectParameter('2.5', 'numeric', 2.5);

    final pgRow = (await binary
            .executePgRows("select 'NaN'::numeric a, 'Infinity'::numeric b, "
                "'-Infinity'::numeric c, 2.5::numeric d"))
        .single;
    expect(pgRow.getNumericDouble(0), isNaN);
    expect(pgRow.getNumericDouble(1), double.infinity);
    expect(pgRow.getNumericDouble(2), double.negativeInfinity);
    expect(pgRow.getNumericDouble(3), 2.5);
  });

  test('numeric loses precision as double; rawText keeps the exact text',
      () async {
    if (!available) return;
    const exact = '12345678901234567890.123456789';
    // By default numeric is the nearest double (exact options: `Decode
    // Numeric As String`, `Use Custom Decimal`; real_numeric_exact_test).
    await expectValue('$exact::numeric', 12345678901234567890.123456789);
    final raw = await text.executeMaps('select $exact::numeric as v',
        resultMode: PgResultMode.rawText);
    expect(raw.single['v'], exact);
    final rawBinary = await binary.executeMaps('select ?::numeric as v',
        parameters: _params([exact]), resultMode: PgResultMode.rawText);
    expect(rawBinary.single['v'], exact);
  });

  test('float NaN and infinities', () async {
    if (!available) return;
    await expectValue("'NaN'::float8", isNaN);
    await expectValue("'Infinity'::float8", double.infinity);
    await expectValue("'-Infinity'::float4", double.negativeInfinity);
    await expectValue('1.5::float4', 1.5);
    await expectParameter(double.nan, 'float8', isNaN);
    await expectParameter(double.infinity, 'float8', double.infinity);
    await expectParameter(-0.25, 'float8', -0.25);
  });

  test('bool', () async {
    if (!available) return;
    await expectValue('true', isTrue);
    await expectValue('false', isFalse);
    await expectParameter(true, 'bool', isTrue);
    await expectParameter(false, 'bool', isFalse);
  });

  test('text: UTF-8, padding, name and "char"', () async {
    if (!available) return;
    const s = 'ção 日本 😀 \' " \\';
    await expectParameter(s, 'text', s);
    await expectValue("'ção 日本 😀'::text", 'ção 日本 😀');
    await expectValue("'ab'::char(4)", 'ab  ');
    await expectValue("'v'::varchar(3)", 'v');
    await expectValue("'nm'::name", 'nm');
    await expectValue("'x'::\"char\"", 'x');
    await expectValue("'<a>ç</a>'::xml", '<a>ç</a>');
    await expectParameter('', 'text', '');
  });

  test('text in a WIN1252 client encoding', () async {
    if (!available) return;
    final conn =
        (await openRealConnectionOrSkip(options: 'Client Encoding=WIN1252'))!;
    try {
      expect(await conn.executeScalar('show client_encoding'), 'WIN1252');
      expect(await conn.executeScalar("select 'Café €'::text"), 'Café €');
      expect(
          await conn.executeScalar('select ?::text',
              parameters: _params(['Ação €'])),
          'Ação €');
      expect(
          await conn.executeScalar('select length(?)',
              parameters: _params(['Ação €'])),
          6);
    } finally {
      await conn.close();
    }
  });

  test('bytea', () async {
    if (!available) return;
    final bytes = Uint8List.fromList([0xde, 0xad, 0xbe, 0xef]);
    await expectValue(r"'\xdeadbeef'::bytea", bytes);
    await expectValue("''::bytea", isEmpty);
    final all = Uint8List.fromList(List.generate(256, (i) => i));
    await expectParameter(all, 'bytea', all);
    expect(
        await text.executeScalar('select ?::bytea[]',
            parameters: _params([
              [bytes, null]
            ])),
        [bytes, null]);
  });

  test('uuid, json and jsonb', () async {
    if (!available) return;
    const id = 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11';
    await expectValue("'$id'::uuid", id);
    await expectParameter(id, 'uuid', id);
    const doc = '{"a": [1, 2, {"b": null}], "c": "ç"}';
    final decoded = {
      'a': [
        1,
        2,
        {'b': null}
      ],
      'c': 'ç'
    };
    await expectValue("'$doc'::json", decoded);
    await expectValue("'$doc'::jsonb", decoded);
    await expectParameter(decoded, 'jsonb', decoded);
    // A mixed list is no PostgreSQL array: send JSON arrays as text.
    await expectParameter('[1, "x", true]', 'json', [1, 'x', true]);
    await expectValue("'null'::jsonb", isNull);
    await expectParameter(
        [
          {'n': 1}
        ],
        'jsonb',
        [
          {'n': 1}
        ]);
  });

  test('date and timestamps, BC and infinity included', () async {
    if (!available) return;
    await expectValue("'2020-02-29'::date", DateTime.utc(2020, 2, 29));
    // Text-format BC values threw FormatException (and, before 1.0.3,
    // shifted every later result).
    await expectValue("'0044-03-15 BC'::date", DateTime.utc(-43, 3, 15));
    await expectValue("'0001-01-01 BC'::date", DateTime.utc(0, 1, 1));
    await expectValue("'2020-01-02 03:04:05.123456'::timestamp",
        DateTime.utc(2020, 1, 2, 3, 4, 5, 123, 456));
    await expectValue("'0044-03-15 10:00:00.5 BC'::timestamp",
        DateTime.utc(-43, 3, 15, 10, 0, 0, 500));
    await expectValue("'2020-01-02 03:04:05.5+02'::timestamptz",
        DateTime.utc(2020, 1, 2, 1, 4, 5, 500));
    await expectValue("'0044-03-15 10:00:00+00 BC'::timestamptz",
        DateTime.utc(-43, 3, 15, 10));
    await expectValue("'infinity'::date", isNull);
    await expectValue("'infinity'::timestamp", isNull);
    await expectValue("'-infinity'::timestamptz", isNull);

    await expectParameter(
        DateTime.utc(2020, 1, 2), 'date', DateTime.utc(2020, 1, 2));
    await expectParameter(DateTime.utc(2020, 1, 2, 3, 4, 5, 6, 7),
        'timestamptz', DateTime.utc(2020, 1, 2, 3, 4, 5, 6, 7));
    await expectParameter(DateTime.utc(2020, 1, 2, 3, 4, 5), 'timestamp',
        DateTime.utc(2020, 1, 2, 3, 4, 5));
    await expectParameter('2020-01-02 03:04:05+02', 'timestamptz',
        DateTime.utc(2020, 1, 2, 1, 4, 5));
  });

  test('time and timetz come back as PostgreSQL prints them', () async {
    if (!available) return;
    // Binary values came back as raw bytes.
    await expectValue("'12:34:56.789'::time", '12:34:56.789');
    await expectValue("'00:00'::time", '00:00:00');
    await expectValue("'24:00'::time", '24:00:00');
    await expectValue("'12:34:56.5+05:30'::timetz", '12:34:56.5+05:30');
    await expectValue("'12:34:56+03'::timetz", '12:34:56+03');
    await expectValue("'00:00:00-03:30:15'::timetz", '00:00:00-03:30:15');
    await expectValue("'23:59:59.999999'::time", '23:59:59.999999');
    await expectParameter('12:34:56.5', 'time', '12:34:56.5');
    await expectParameter('12:34:56.5', 'time', '12:34:56.5',
        dbType: DpgsqlDbType.time);
    await expectValue("array['01:02:03'::time, null]", ['01:02:03', null]);
  });

  test('interval', () async {
    if (!available) return;
    await expectValue(
        "'1 year 2 mons 3 days 04:05:06.7'::interval",
        isA<DpgsqlInterval>()
            .having((i) => i.months, 'months', 14)
            .having((i) => i.days, 'days', 3)
            .having((i) => i.time, 'time', 14706700000));
    await expectValue(
        "'-1 days -00:00:01'::interval",
        isA<DpgsqlInterval>()
            .having((i) => i.days, 'days', -1)
            .having((i) => i.time, 'time', -1000000));
  });

  test('arrays, NULL elements and nesting included', () async {
    if (!available) return;
    await expectValue('array[1, null, 3]::int4[]', [1, null, 3]);
    await expectValue("'{}'::int4[]", isEmpty);
    await expectValue("'{{1,2},{3,4}}'::int4[]", [
      [1, 2],
      [3, 4]
    ]);
    await expectValue(
        "array['a b', null, 'c,d', 'e\"f', 'g\\h', 'NULL']::text[]",
        ['a b', null, 'c,d', 'e"f', r'g\h', 'NULL']);
    // These element types came back as raw bytes (binary) or as the array
    // literal text (`{1,2}`).
    await expectValue('array[1, null]::int2[]', [1, null]);
    await expectValue('array[9223372036854775807, null]::int8[]',
        [9223372036854775807, null]);
    await expectValue('array[1.5, null]::numeric[]', [1.5, null]);
    await expectValue("array['x', null]::varchar[]", ['x', null]);
    await expectValue(
        "array['2020-01-02', null]::date[]", [DateTime.utc(2020, 1, 2), null]);
    await expectValue("array['2020-01-02 03:04:05+00']::timestamptz[]",
        [DateTime.utc(2020, 1, 2, 3, 4, 5)]);
    await expectValue("array['a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11']::uuid[]",
        ['a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11']);
    await expectValue("array['{\"a\": 1}']::jsonb[]", [
      {'a': 1}
    ]);
    await expectValue("array['10.0.0.1']::inet[]", ['10.0.0.1']);
    await expectValue('array[1]::oid[]', [1]);
    await expectValue('array[true, null]', [true, null]);
    await expectValue('array[1.5, null]::float8[]', [1.5, null]);

    await expectParameter([1, null, 3], 'int4[]', [1, null, 3]);
    await expectParameter(['a', null, 'b"c'], 'text[]', ['a', null, 'b"c']);
    await expectParameter([true, false], 'bool[]', [true, false]);
    await expectParameter([1.5, null], 'float8[]', [1.5, null]);
  });

  test('inet and cidr', () async {
    if (!available) return;
    await expectValue("'10.0.0.1/8'::inet", '10.0.0.1/8');
    await expectValue("'192.168.0.1'::inet", '192.168.0.1');
    await expectValue("'10.0.0.0/8'::cidr", '10.0.0.0/8');
    await expectValue("'::1'::inet", '::1');
    await expectParameter('10.1.2.3/16', 'inet', '10.1.2.3/16');
  });

  test('money in the server locale', () async {
    if (!available) return;
    // The text form follows lc_monetary (pt_BR: `R$ 1.234,56`): its decimal
    // comma was dropped, 100 times the value.
    await expectValue('1234.56::money', DpgsqlMoney(123456));
    await expectValue('(-1.5)::money', DpgsqlMoney(-150));
    await expectValue('0::money', DpgsqlMoney(0));
  });

  test('enum values and parameters', () async {
    if (!available) return;
    await text.executeMaps('drop type if exists cov_mood');
    await text.executeMaps("create type cov_mood as enum ('sad', 'happy')");
    try {
      // The text format decodes as String. The binary format has no handler
      // for the type's OID (limitation: cast to text).
      expect(await text.executeScalar("select 'happy'::cov_mood"), 'happy');
      await expectValue("'happy'::cov_mood::text", 'happy');
      await expectParameter('sad', 'cov_mood::text', 'sad');
      expect(
          await text.executeScalar(
              "select array['sad', 'happy']::cov_mood[]::text[]"),
          ['sad', 'happy']);
      expect(
          await text.executeScalar('select ? = any(enum_range(null::cov_mood))',
              parameters: _params(['happy'])),
          isTrue);
    } finally {
      await text.executeMaps('drop type if exists cov_mood');
    }
  });

  test('PgRow views from executePgRows without a prepared statement', () async {
    if (!available) return;
    // Rows were rebuilt from the values' text with names column_0, ...:
    // getInt/getDouble threw and getByName did not find the columns.
    for (final conn in [text, binary]) {
      final row = (await conn.executePgRows(
              "select 5::int4 as id, 'x' as name, 2.5::float8 as f, "
              "'2020-01-02 03:04:05'::timestamp as t, null::int as n"))
          .single;
      expect(row.columnNames, ['id', 'name', 'f', 't', 'n']);
      expect(row.getInt(0), 5);
      expect(row.getString(1), 'x');
      expect(row.getDouble(2), 2.5);
      expect(row.getDateTime(3), DateTime.utc(2020, 1, 2, 3, 4, 5));
      expect(row.isNull(4), isTrue);
      expect(row.getByName('id'), isNotNull);
      final withParameter = (await conn.executePgRows('select ?::int8 as id',
              parameters: _params([1 << 40])))
          .single;
      expect(withParameter.getInt(0), 1 << 40);
    }
  });

  test('a value that fails to decode does not shift later results', () async {
    if (!available) return;
    // An infinite date inside an array has no DateTime (the element decoder
    // throws); any decoding error used to leave the response unread.
    const failing = "select array['infinity'::date] as v";
    for (final conn in [text, binary]) {
      for (var i = 0; i < 3; i++) {
        await expectLater(conn.executeMaps(failing), throwsA(anything));
        expect(await conn.executeScalar('select $i'), i);
        await expectLater(conn.executeRows(failing), throwsA(anything));
        expect(await conn.executeMaps('select $i as v'), [
          {'v': i}
        ]);
        final cmd = conn.createCommand(failing);
        await cmd.prepare();
        await expectLater(cmd.executeMaps(), throwsA(anything));
        await expectLater(cmd.executeRows(), throwsA(anything));
        await expectLater(cmd.executeScalar(), throwsA(anything));
        expect(await conn.executeRows('select $i'), [
          [i]
        ]);
      }
    }
  });
}
