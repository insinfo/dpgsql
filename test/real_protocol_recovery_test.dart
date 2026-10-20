// Regression tests for 1.0.3: protocol state after errors raised while rows
// are being read (cancel, fast paths), Map/List parameters and concurrent use
// of a single connection.

import 'package:dpgsql/dpgsql.dart';
import 'package:test/test.dart';

import 'test_config.dart';

DpgsqlParameterCollection _params(List<Object?> values) {
  final parameters = DpgsqlParameterCollection();
  for (var i = 0; i < values.length; i++) {
    parameters.add(DpgsqlParameter('p$i', values[i]));
  }
  return parameters;
}

void main() {
  test('a cancelled statement does not shift the next results', () async {
    final conn = await openRealConnectionOrSkip();
    if (conn == null) return;
    try {
      final slow = conn.executeMaps('select pg_sleep(5) as s');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await conn.cancel();
      await expectLater(
          slow,
          throwsA(isA<PostgresException>()
              .having((e) => e.sqlState, 'sqlState', '57014')));

      // The ReadyForQuery that follows the error used to be left unread: the
      // next command returned [] and every later one the previous result.
      expect(await conn.executeMaps('select 1 as one'), [
        {'one': 1}
      ]);
      expect(await conn.executeMaps('select 2 as two'), [
        {'two': 2}
      ]);
    } finally {
      await conn.close();
    }
  });

  test('an error after RowDescription keeps the reader paths in sync',
      () async {
    final conn = await openRealConnectionOrSkip();
    if (conn == null) return;
    try {
      // The division fails on the second row, after rows were already sent.
      const failing = 'select 1 / (2 - g) as v from generate_series(1, 3) g';
      await expectLater(conn.executeMaps(failing), throwsA(isA<PostgresException>()));
      expect(await conn.executeScalar('select 7'), 7);

      final reader = await conn.executeReader(failing);
      await expectLater(() async {
        while (await reader.read()) {}
      }(), throwsA(isA<PostgresException>()));
      await reader.close();
      expect(await conn.executeScalar('select 8'), 8);

      // Prepared fast path.
      final cmd = conn.createCommand('select 10 / (? - g) as v '
          'from generate_series(1, 3) g');
      cmd.parameters.addAll(_params([2]));
      await cmd.prepare();
      await expectLater(cmd.executeRows(), throwsA(isA<PostgresException>()));
      expect(await conn.executeScalar('select 9'), 9);
    } finally {
      await conn.close();
    }
  });

  test('Map parameters are sent as JSON', () async {
    final conn = await openRealConnectionOrSkip();
    if (conn == null) return;
    try {
      final rows = await conn.executeMaps('select ?::jsonb as j, ?::json as k',
          parameters: _params([
            {'a': 1, 'b': 'x'},
            [
              {'n': 1},
              {'n': 2}
            ],
          ]));
      expect(rows.single['j'], {'a': 1, 'b': 'x'});
      expect(rows.single['k'], [
        {'n': 1},
        {'n': 2}
      ]);
    } finally {
      await conn.close();
    }
  });

  test('string lists are inferred from the context (uuid = any(?))',
      () async {
    final conn = await openRealConnectionOrSkip();
    if (conn == null) return;
    try {
      const id = 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11';
      final rows = await conn.executeMaps(
          "select '$id'::uuid = any(?) as hit, ?::text[] as t",
          parameters: _params([
            [id],
            ['a b', 'c,d', 'e"f', r'g\h', null],
          ]));
      expect(rows.single['hit'], isTrue);
      expect(rows.single['t'], ['a b', 'c,d', 'e"f', r'g\h', null]);
    } finally {
      await conn.close();
    }
  });

  test('a second concurrent command fails clearly and leaves the first intact',
      () async {
    final conn = await openRealConnectionOrSkip();
    if (conn == null) return;
    try {
      final first = conn.executeMaps('select pg_sleep(0.3), 1 as a');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await expectLater(
          conn.executeMaps('select 2 as b'),
          throwsA(isA<StateError>().having((e) => e.message, 'message',
              contains('another command is still running'))));
      expect((await first).single['a'], 1);

      final reader = await conn.executeReader('select 1 as a');
      await expectLater(conn.executeScalar('select 2'), throwsStateError);
      await reader.close();
      expect(await conn.executeScalar('select 3'), 3);
    } finally {
      await conn.close();
    }
  });
}
