// Result columns without a binary decoder (enums, tsvector, reg*, arrays of
// user-defined types) are requested in text and come back as the server's
// text on every path; they used to come back as their binary bytes, which
// could not be told apart from bytea. float4 gives the same double in text
// and in binary.

import 'package:dpgsql/dpgsql.dart';
import 'package:test/test.dart';

import 'test_config.dart';

DpgsqlParameterCollection? _params(List<Object?>? values) {
  if (values == null) return null;
  final parameters = DpgsqlParameterCollection();
  for (var i = 0; i < values.length; i++) {
    parameters.add(DpgsqlParameter('p$i', values[i]));
  }
  return parameters;
}

/// [sql]'s single value on every path, each run several times (one-shot,
/// auto-prepared, prepared fast path).
Future<List<Object?>> _readEverywhere(DpgsqlConnection conn, String sql,
    [List<Object?>? values]) async {
  final read = <Object?>[];
  for (var run = 0; run < 4; run++) {
    read
      ..add(await conn.executeScalar(sql, parameters: _params(values)))
      ..add((await conn.executeMaps(sql, parameters: _params(values)))
          .single
          .values
          .single)
      ..add((await conn.executeRows(sql, parameters: _params(values)))
          .single
          .single);
    final reader = await conn.executeReader(sql, parameters: _params(values));
    try {
      expect(await reader.read(), isTrue);
      read.add(reader.getValue(0));
    } finally {
      await reader.close();
    }
  }
  final cmd = conn.createCommand(sql);
  final parameters = _params(values);
  if (parameters != null) cmd.parameters.addAll(parameters);
  await cmd.prepare();
  read
    ..add((await cmd.executeMaps()).single.values.single)
    ..add(await cmd.executeScalar());
  return read;
}

void main() {
  final connections = <String, DpgsqlConnection>{};
  var available = true;

  setUpAll(() async {
    for (final (name, options) in [
      ('simple', null),
      ('extended', 'Use Extended Query For Unparameterized Commands=true'),
      (
        'extended auto-prepare',
        'Use Extended Query For Unparameterized Commands=true;'
            'Max Auto Prepare=16;Auto Prepare Min Usages=2'
      ),
    ]) {
      final conn = await openRealConnectionOrSkip(options: options);
      if (conn == null) {
        available = false;
        return;
      }
      connections[name] = conn;
    }
    final conn = connections['simple']!;
    await conn.executeMaps('drop type if exists cov_fmt_mood cascade');
    await conn.executeMaps("create type cov_fmt_mood as enum ('ok', 'sad')");
    await conn.executeMaps('drop domain if exists cov_fmt_dom');
    await conn.executeMaps('create domain cov_fmt_dom as text');
  });

  tearDownAll(() async {
    if (!available) return;
    await connections['simple']!
        .executeMaps('drop type if exists cov_fmt_mood cascade');
    await connections['simple']!
        .executeMaps('drop domain if exists cov_fmt_dom');
    for (final conn in connections.values) {
      await conn.close();
    }
  });

  test('types without a binary decoder come back as the server text', () async {
    if (!available) return;
    for (final expr in [
      "'ok'::cov_fmt_mood",
      "'{ok,sad}'::cov_fmt_mood[]",
      "'a b'::tsvector",
      "'pg_class'::regclass",
      "'int4'::regtype",
      "'x'::cov_fmt_dom",
    ]) {
      final expected =
          await connections['simple']!.executeScalar('select ($expr)::text');
      for (final entry in connections.entries) {
        final read = await _readEverywhere(entry.value, 'select $expr as v');
        for (var i = 0; i < read.length; i++) {
          expect(read[i], expected, reason: '$expr, ${entry.key}, path $i');
        }
        // With a parameter: the extended protocol on every connection.
        final withParam = await _readEverywhere(
            entry.value, 'select $expr as v where ?::int = 1', [1]);
        expect(withParam, everyElement(expected),
            reason: '$expr, ${entry.key}, with a parameter');
      }
    }
  });

  test('a row mixing binary and text columns', () async {
    if (!available) return;
    for (final entry in connections.entries) {
      for (var run = 0; run < 4; run++) {
        final row = (await entry.value
                .executeMaps("select 1 as i, 'ok'::cov_fmt_mood as e, "
                    "'2024-03-10'::date as d, 'a'::tsvector as t, true as b"))
            .single;
        expect(
            row,
            {
              'i': 1,
              'e': 'ok',
              'd': DateTime.utc(2024, 3, 10),
              't': "'a'",
              'b': true,
            },
            reason: '${entry.key}, run $run');
      }
    }
  });

  test('float4 is the same double in text and in binary', () async {
    if (!available) return;
    for (final entry in connections.entries) {
      final read = await _readEverywhere(entry.value, 'select 1.1::float4');
      expect(read, everyElement(1.100000023841858), reason: entry.key);
    }
  });
}
