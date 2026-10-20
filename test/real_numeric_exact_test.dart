// Exact `numeric`: `Decode Numeric As String` returns the server's text and
// `Use Custom Decimal` a DpgsqlDecimal, on every read path, in the text and
// the binary formats. Without them numeric is the nearest double.

import 'package:dpgsql/dpgsql.dart';
import 'package:test/test.dart';

import 'test_config.dart';

const _values = [
  '0',
  '0.00',
  '1',
  '-1.5',
  '150.50',
  '10000',
  '99990000',
  '0.0001',
  '0.00001234',
  '-0.000000000000000000001',
  '12345678901234567890.123456789',
  '123456789012345678901234567890',
  '1e-20',
  '1.000000000000000000000000000001',
  'NaN',
  'Infinity',
  '-Infinity',
];

DpgsqlParameterCollection? _params(List<Object?>? values) {
  if (values == null) return null;
  final parameters = DpgsqlParameterCollection();
  for (var i = 0; i < values.length; i++) {
    parameters.add(DpgsqlParameter('p$i', values[i]));
  }
  return parameters;
}

/// [sql]'s single value read by every path (fast paths, reader, prepared).
Future<List<Object?>> _readEverywhere(DpgsqlConnection conn, String sql,
    [List<Object?>? values]) async {
  final read = <Object?>[
    await conn.executeScalar(sql, parameters: _params(values)),
    (await conn.executeMaps(sql, parameters: _params(values)))
        .single
        .values
        .single,
    (await conn.executeRows(sql, parameters: _params(values))).single.single,
  ];
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
  read.add(await cmd.executeScalar());
  return read;
}

void main() {
  final connections = <String, DpgsqlConnection>{};
  var available = true;

  setUpAll(() async {
    const binary = 'Use Extended Query For Unparameterized Commands=true';
    for (final (name, options) in [
      ('string text', 'Decode Numeric As String=true'),
      ('string binary', 'Decode Numeric As String=true;$binary'),
      ('decimal text', 'Use Custom Decimal=true'),
      ('decimal binary', 'Use Custom Decimal=true;$binary'),
      ('default', null),
    ]) {
      final conn = await openRealConnectionOrSkip(options: options);
      if (conn == null) {
        available = false;
        return;
      }
      connections[name] = conn;
    }
  });

  tearDownAll(() async {
    for (final conn in connections.values) {
      await conn.close();
    }
  });

  /// What PostgreSQL prints for [value] (`numeric_out`).
  Future<String> serverText(String value) async =>
      (await connections['default']!
          .executeScalar("select '$value'::numeric::text")) as String;

  test('Decode Numeric As String returns the server text on every path',
      () async {
    if (!available) return;
    for (final value in _values) {
      final expected = await serverText(value);
      for (final name in ['string text', 'string binary']) {
        final conn = connections[name]!;
        final read =
            await _readEverywhere(conn, "select '$value'::numeric as v");
        for (var i = 0; i < read.length; i++) {
          expect(read[i], expected, reason: '$value, $name, path $i');
        }
        // Binary: the value comes back as a parameter too.
        final param =
            await _readEverywhere(conn, 'select ?::numeric as v', [expected]);
        expect(param, everyElement(expected), reason: '$value, $name, param');
      }
    }
  });

  test('a numeric(p, s) column keeps its scale', () async {
    if (!available) return;
    for (final name in ['string text', 'string binary']) {
      final conn = connections[name]!;
      final rows = await conn
          .executeMaps('select 150.5::numeric(10,2) a, 0::numeric(5,3) b, '
              '-7::numeric(4,0) c');
      expect(rows.single, {'a': '150.50', 'b': '0.000', 'c': '-7'},
          reason: name);
    }
  });

  test('numeric arrays are lists of exact strings', () async {
    if (!available) return;
    for (final name in ['string text', 'string binary']) {
      final rows = await connections[name]!.executeMaps(
          "select '{1.10,NULL,-0.001,12345678901234567890.5}'::numeric[] v");
      expect(
          rows.single['v'], ['1.10', null, '-0.001', '12345678901234567890.5'],
          reason: name);
    }
  });

  test('Use Custom Decimal returns an exact DpgsqlDecimal', () async {
    if (!available) return;
    for (final value in _values.where((v) => !v.contains('Inf'))) {
      final expected = await serverText(value);
      for (final name in ['decimal text', 'decimal binary']) {
        final read = await _readEverywhere(
            connections[name]!, "select '$value'::numeric as v");
        for (var i = 0; i < read.length; i++) {
          expect(read[i], isA<DpgsqlDecimal>(),
              reason: '$value, $name, path $i');
          expect(read[i].toString(), expected,
              reason: '$value, $name, path $i');
        }
      }
    }
  });

  test('DpgsqlDecimal, String and num parameters are sent exactly', () async {
    if (!available) return;
    const exact = '12345678901234567890.123456789';
    for (final name in connections.keys) {
      final conn = connections[name]!;
      final sent = <Object>[
        DpgsqlDecimal.parse(exact),
        exact,
      ];
      for (final value in sent) {
        final parameter = DpgsqlParameter('p0', value)
          ..dpgsqlDbType = DpgsqlDbType.numeric;
        final parameters = DpgsqlParameterCollection()..add(parameter);
        expect(
            await conn.executeScalar('select (?::numeric)::text',
                parameters: parameters),
            exact,
            reason: '$name, ${value.runtimeType}');
      }
      final double = DpgsqlParameter('p0', 2.5)
        ..dpgsqlDbType = DpgsqlDbType.numeric;
      expect(
          await conn.executeScalar('select (?::numeric)::text',
              parameters: DpgsqlParameterCollection()..add(double)),
          '2.5',
          reason: name);
    }
  });

  test('without either option numeric is still the nearest double', () async {
    if (!available) return;
    final value =
        await connections['default']!.executeScalar("select '150.50'::numeric");
    expect(value, 150.5);
  });
}
