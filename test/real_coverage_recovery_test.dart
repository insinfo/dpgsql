// Error and recovery paths against a real server: cancel(), statement
// timeouts, a backend terminated from another connection, COPY errors,
// readers closed early, prepared statements invalidated by schema changes,
// plus the regressions found by the coverage tests. After each failure the
// connection must return the next command's own result (or fail fast), never
// a previous response and never hang.

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

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

Matcher _sqlState(String state) =>
    isA<PostgresException>().having((e) => e.sqlState, 'sqlState', state);

/// The next commands on [conn] return their own results.
Future<void> _expectInSync(DpgsqlConnection conn, [int seed = 0]) async {
  expect(await conn.executeScalar('select ${seed + 1}'), seed + 1);
  expect(await conn.executeMaps('select ${seed + 2} as v'), [
    {'v': seed + 2}
  ]);
  expect(await conn.executeRows('select ?::int', parameters: _params([seed])), [
    [seed]
  ]);
}

/// Spawned by the cancel() test: the isolate must exit by itself.
Future<void> _cancelInIsolate(String connectionString) async {
  final conn = DpgsqlConnection(connectionString);
  await conn.open();
  await conn.cancel();
  await conn.close();
}

void main() {
  group('cancel()', () {
    test('a running statement fails with 57014 on every entry point', () async {
      final conn = await openRealConnectionOrSkip();
      if (conn == null) return;
      try {
        final runs = <String, Future<Object?> Function()>{
          'executeMaps': () => conn.executeMaps('select pg_sleep(5)'),
          'executeRows': () => conn.executeRows('select pg_sleep(?)',
              parameters: _params([5.0])),
          'executeScalar': () => conn.executeScalar('select pg_sleep(5)'),
          'executeReader': () async {
            final reader = await conn.executeReader('select pg_sleep(5)');
            try {
              while (await reader.read()) {}
            } finally {
              await reader.close();
            }
            return null;
          },
          'prepared command': () async {
            final cmd = conn.createCommand('select pg_sleep(?) as s')
              ..parameters.addWithValue('s', 5.0);
            await cmd.prepare();
            return cmd.executeMaps();
          },
          'batch': () async {
            final batch = conn.createBatch()
              ..createBatchCommand('select pg_sleep(5)')
              ..createBatchCommand('select 1');
            final reader = await batch.executeReader();
            try {
              do {
                while (await reader.read()) {}
              } while (await reader.nextResult());
            } finally {
              await reader.close();
            }
            return null;
          },
        };
        var seed = 0;
        for (final MapEntry(key: name, value: run) in runs.entries) {
          final failed =
              expectLater(run(), throwsA(_sqlState('57014')), reason: name);
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await conn.cancel();
          await failed;
          await _expectInSync(conn, seed += 10);
        }
      } finally {
        await conn.close();
      }
    });

    test('a reader that already returned rows fails with 57014', () async {
      final conn = await openRealConnectionOrSkip();
      if (conn == null) return;
      try {
        // The second row pushes the first one out of the server's output
        // buffer, so the first row arrives before the sleep.
        final reader = await conn.executeReader(
            "select repeat('x', 100000) as v union all "
            "select repeat('y', 100000) union all select pg_sleep(5)::text");
        expect(await reader.read(), isTrue);
        expect((reader[0] as String).length, 100000);
        final failed = expectLater(() async {
          while (await reader.read()) {}
        }(), throwsA(_sqlState('57014')));
        await conn.cancel();
        await failed;
        await reader.close();
        await _expectInSync(conn);
      } finally {
        await conn.close();
      }
    });

    test('cancel() does not keep the isolate alive', () async {
      if (await openRealConnectionOrSkip().then((c) async {
        await c?.close();
        return c == null;
      })) {
        return;
      }
      // The cancel request's socket was never read to its end, so it stayed
      // open and the process did not exit.
      final exit = ReceivePort();
      final errors = ReceivePort();
      await Isolate.spawn(_cancelInIsolate, realConnectionString(),
          onExit: exit.sendPort, onError: errors.sendPort);
      final failed = errors.first.then((e) => fail('isolate failed: $e'));
      await Future.any([exit.first, failed])
          .timeout(const Duration(seconds: 10));
      exit.close();
      errors.close();
    });
  });

  group('timeouts', () {
    test('Statement Timeout fails with 57014 on every protocol', () async {
      final conn =
          await openRealConnectionOrSkip(options: 'Statement Timeout=200ms');
      if (conn == null) return;
      try {
        for (var i = 0; i < 3; i++) {
          await expectLater(conn.executeMaps('select pg_sleep(2)'),
              throwsA(_sqlState('57014')));
          await expectLater(
              conn.executeRows('select pg_sleep(?)',
                  parameters: _params([2.0])),
              throwsA(_sqlState('57014')));
          final cmd = conn.createCommand('select pg_sleep(2) as s');
          await cmd.prepare();
          await expectLater(cmd.executeScalar(), throwsA(_sqlState('57014')));
          await _expectInSync(conn, i * 10);
        }
      } finally {
        await conn.close();
      }
    });

    test('a command abandoned by Future.timeout keeps its turn', () async {
      final conn = await openRealConnectionOrSkip();
      if (conn == null) return;
      try {
        // The driver has no client-side command timeout: the abandoned
        // command still runs, and later commands wait for it instead of
        // reading its response.
        await expectLater(
            conn
                .executeMaps('select pg_sleep(0.5), 1 as a')
                .timeout(const Duration(milliseconds: 100)),
            throwsA(isA<TimeoutException>()));
        expect(await conn.executeScalar('select 2'), 2);
        await _expectInSync(conn);
      } finally {
        await conn.close();
      }
    });
  });

  group('pg_terminate_backend', () {
    test('the running and the queued callers fail instead of hanging',
        () async {
      final victim = await openRealConnectionOrSkip();
      if (victim == null) return;
      final killer = (await openRealConnectionOrSkip())!;
      try {
        final pid = await victim.executeScalar('select pg_backend_pid()');
        final lost = victim.onConnectionLost.first;
        final running = victim.executeMaps('select pg_sleep(5)');
        final queued = [
          victim.executeMaps('select 2'),
          victim.executeScalar('select 3'),
          victim.executeRows('select ?::int', parameters: _params([4])),
        ];
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await killer.executeScalar('select pg_terminate_backend($pid)');
        await lost.timeout(const Duration(seconds: 5));
        for (final call in [running, ...queued]) {
          await expectLater(
              call.timeout(const Duration(seconds: 5)), throwsA(anything));
        }
        await expectLater(
            victim
                .executeScalar('select 5')
                .timeout(const Duration(seconds: 5)),
            throwsA(anything));
      } finally {
        await victim.close();
        await killer.close();
      }
    });

    test('a pooled connection terminated while idle is replaced', () async {
      final killer = await openRealConnectionOrSkip();
      if (killer == null) return;
      final dataSource =
          DpgsqlDataSource('${realConnectionString()};Maximum Pool Size=1');
      try {
        final first = await dataSource.openConnection();
        final pid = await first.executeScalar('select pg_backend_pid()');
        await first.close();
        await killer.executeScalar('select pg_terminate_backend($pid)');
        await Future<void>.delayed(const Duration(milliseconds: 300));

        final second = await dataSource.openConnection();
        try {
          expect(await second.executeScalar('select pg_backend_pid()'),
              isNot(pid));
          await _expectInSync(second);
        } finally {
          await second.close();
        }
      } finally {
        await dataSource.dispose();
        await killer.close();
      }
    });
  });

  group('COPY', () {
    late DpgsqlConnection conn;
    var available = true;

    setUp(() async {
      final opened = await openRealConnectionOrSkip();
      if (opened == null) {
        available = false;
        return;
      }
      conn = opened;
      await conn.executeMaps('drop table if exists cov_copy');
      await conn.executeMaps('create table cov_copy (a int)');
    });

    tearDown(() async {
      if (!available) return;
      await conn.executeMaps('drop table if exists cov_copy');
      await conn.close();
    });

    // A failed COPY kept the connection's turn: every later command waited
    // forever.
    test('a rejected row in COPY FROM fails, then the connection works',
        () async {
      if (!available) return;
      final text = await conn.beginTextImport('copy cov_copy from stdin');
      await text.writeString('1\nabc\n3\n');
      await expectLater(text.complete(), throwsA(_sqlState('22P02')));
      expect(text.isClosed, isTrue);
      await _expectInSync(conn);

      final binary = await conn
          .beginBinaryImport('copy cov_copy from stdin (format binary)');
      await binary.startRow(1);
      await binary.write('not an int');
      await expectLater(binary.complete(), throwsA(isA<PostgresException>()));
      await _expectInSync(conn, 10);
      expect(await conn.executeScalar('select count(*) from cov_copy'), 0);
    });

    test('an error in the middle of COPY TO fails, then the connection works',
        () async {
      if (!available) return;
      const failing = 'copy (select 10 / (g - 3) from generate_series(1, 5) g) '
          'to stdout';
      final raw = await conn.beginTextExport(failing);
      await expectLater(raw.readAsString(), throwsA(_sqlState('22012')));
      await raw.dispose();
      await _expectInSync(conn);

      final binary = await conn.beginBinaryExport('$failing (format binary)');
      await expectLater(() async {
        while (await binary.startRow() != -1) {
          await binary.read<int>();
        }
      }(), throwsA(_sqlState('22012')));
      // dispose() waited for a ReadyForQuery already read.
      await binary.dispose().timeout(const Duration(seconds: 5));
      await _expectInSync(conn, 10);
    });

    test('COPY TO closed before its end, then the connection works', () async {
      if (!available) return;
      // The rest of the data used to be left unread: the next command read
      // it as its own result.
      final raw = await conn.beginTextExport(
          'copy (select g from generate_series(1, 100000) g) to stdout');
      expect(await raw.read(), isNotNull);
      await raw.dispose();
      await _expectInSync(conn);

      final binary = await conn.beginBinaryExport(
          'copy (select g from generate_series(1, 100000) g) to stdout '
          '(format binary)');
      expect(await binary.startRow(), 1);
      expect(await binary.read<int>(), 1);
      await binary.dispose();
      await _expectInSync(conn, 10);
    });

    test('a cancelled COPY FROM is rolled back and the connection works',
        () async {
      if (!available) return;
      // The error that answers CopyFail used to be left unread for the next
      // command.
      final raw = await conn.beginTextImport('copy cov_copy from stdin');
      await raw.writeString('1\n2\n');
      await raw.cancel();
      await _expectInSync(conn);

      final binary = await conn
          .beginBinaryImport('copy cov_copy from stdin (format binary)');
      await binary.startRow(1);
      await binary.write(1);
      await binary.close();
      await _expectInSync(conn, 10);
      expect(await conn.executeScalar('select count(*) from cov_copy'), 0);
      expect(conn.isSafeToReturnToPool, isFalse);
    });

    test('a COPY command that fails before starting', () async {
      if (!available) return;
      await expectLater(
          conn.beginTextImport('copy cov_copy_missing from stdin'),
          throwsA(_sqlState('42P01')));
      await _expectInSync(conn);
    });
  });

  group('readers closed early', () {
    test('mid-result, on every reader kind', () async {
      final conn = await openRealConnectionOrSkip();
      if (conn == null) return;
      try {
        const big =
            'select g, repeat(\'x\', 100) from generate_series(1, 50000) g';
        final readers = <String, Future<DpgsqlDataReader> Function()>{
          'executeReader': () => conn.executeReader(big),
          'executeReader + parameter': () => conn.executeReader(
              'select g from generate_series(1, ?) g',
              parameters: _params([50000])),
          'query': () => conn.query('select g from generate_series(1, ?) g',
              substitutionValues: [50000]),
          'prepared command': () async {
            final cmd = conn.createCommand(big);
            await cmd.prepare();
            return cmd.executeReader();
          },
          'batch': () {
            final batch = conn.createBatch()
              ..createBatchCommand(big)
              ..createBatchCommand('select 42');
            return batch.executeReader();
          },
          'executeCommandsPipelined': () => conn.executeCommandsPipelined([
                conn.createCommand(big),
                conn.createCommand('select 42'),
              ]),
        };
        var seed = 0;
        for (final MapEntry(key: name, value: open) in readers.entries) {
          for (final rowsRead in [0, 1, 2]) {
            final reader = await open();
            for (var i = 0; i < rowsRead; i++) {
              expect(await reader.read(), isTrue, reason: name);
              expect(reader[0], i + 1, reason: name);
            }
            await reader.close();
            await _expectInSync(conn, seed += 10);
          }
        }
      } finally {
        await conn.close();
      }
    });

    test('rows stay intact while the caller awaits between reads', () async {
      final conn = await openRealConnectionOrSkip();
      if (conn == null) return;
      try {
        // Bytes already read were overwritten when more data arrived: the
        // current row and the messages queued behind it changed under the
        // caller (wrong values, "Invalid radix-10 number").
        for (final parameters in [
          null,
          _params([20000])
        ]) {
          final reader = await conn.executeReader(
              'select g, repeat(chr(65 + g % 26), 200) as s '
              'from generate_series(1, ${parameters == null ? 20000 : '?'}) g',
              parameters: parameters);
          var n = 0;
          try {
            while (await reader.read()) {
              n++;
              if (n % 50 == 0) {
                await Future<void>.delayed(const Duration(milliseconds: 1));
              }
              expect(reader.getInt(0), n);
              expect(
                  reader.getString(1), String.fromCharCode(65 + n % 26) * 200);
            }
          } finally {
            await reader.close();
          }
          expect(n, 20000);
        }
      } finally {
        await conn.close();
      }
    });

    test('bytea values stay intact after later commands', () async {
      final conn = await openRealConnectionOrSkip();
      if (conn == null) return;
      try {
        final bytes = Uint8List.fromList(List.generate(256, (i) => i));
        final mapped = (await conn.executeMaps('select ?::bytea as b',
                parameters: _params([bytes])))
            .single['b'] as Uint8List;
        final scalar = await conn.executeScalar('select ?::bytea',
            parameters: _params([bytes])) as Uint8List;
        // They were views of the socket buffer, overwritten by later reads.
        await conn.executeRows("select repeat('x', 20000)");
        await conn.executeRows("select repeat('y', 40000)");
        expect(mapped, bytes);
        expect(scalar, bytes);
      } finally {
        await conn.close();
      }
    });
  });

  group('prepared statements and schema changes', () {
    late DpgsqlConnection admin;
    var available = true;

    setUp(() async {
      final opened = await openRealConnectionOrSkip();
      if (opened == null) {
        available = false;
        return;
      }
      admin = opened;
      await admin.executeMaps('drop table if exists cov_schema');
      await admin.executeMaps('create table cov_schema (a int)');
      await admin.executeMaps('insert into cov_schema values (1)');
    });

    tearDown(() async {
      if (!available) return;
      await admin.executeMaps('drop table if exists cov_schema');
      await admin.close();
    });

    test('an explicitly prepared command fails with 0A000, in sync', () async {
      if (!available) return;
      final cmd = admin.createCommand('select * from cov_schema where a = ?')
        ..parameters.addWithValue('a', 1);
      await cmd.prepare();
      expect(await cmd.executeMaps(), [
        {'a': 1}
      ]);
      await admin.executeMaps('alter table cov_schema add column b text');
      // As in Npgsql, an explicitly prepared statement is not re-prepared.
      for (var i = 0; i < 3; i++) {
        await expectLater(cmd.executeMaps(), throwsA(_sqlState('0A000')));
        await expectLater(cmd.executeRows(), throwsA(_sqlState('0A000')));
        await _expectInSync(admin, i * 10);
      }
      final fresh = admin.createCommand('select * from cov_schema where a = ?')
        ..parameters.addWithValue('a', 1);
      await fresh.prepare();
      expect(await fresh.executeMaps(), [
        {'a': 1, 'b': null}
      ]);
    });

    test('an auto-prepared statement fails once, then is prepared again',
        () async {
      if (!available) return;
      for (final options in [
        'Max Auto Prepare=10;Auto Prepare Min Usages=2',
        'Max Auto Prepare=10;Auto Prepare Min Usages=2;'
            'Use Extended Query For Unparameterized Commands=true',
      ]) {
        await admin.executeMaps('drop table if exists cov_schema');
        await admin.executeMaps('create table cov_schema (a int)');
        await admin.executeMaps('insert into cov_schema values (1)');
        final conn = (await openRealConnectionOrSkip(options: options))!;
        try {
          Future<List<Map<String, dynamic>>> query() =>
              conn.executeMaps('select * from cov_schema where a = ?',
                  parameters: _params([1]));
          Future<List<Map<String, dynamic>>> unparameterized() =>
              conn.executeMaps('select * from cov_schema');
          for (var i = 0; i < 4; i++) {
            expect(await query(), [
              {'a': 1}
            ]);
            expect(await unparameterized(), [
              {'a': 1}
            ]);
          }
          // An auto-prepared statement fails once with [state] (the
          // unparameterized one is auto-prepared on the extended protocol
          // only), then works. It used to fail on every later execution.
          Future<void> expectRecovers(
              Future<List<Map<String, dynamic>>> Function() run,
              String state) async {
            try {
              expect(await run(), [
                {'a': 1, 'b': null}
              ]);
            } on PostgresException catch (e) {
              expect(e.sqlState, state);
            }
            // Unique text: never auto-prepared.
            final seed = DateTime.now().microsecondsSinceEpoch % 1000000;
            expect(await conn.executeScalar('select $seed'), seed);
            for (var i = 0; i < 3; i++) {
              expect(await run(), [
                {'a': 1, 'b': null}
              ]);
            }
          }

          await admin.executeMaps('alter table cov_schema add column b text');
          await expectLater(query(), throwsA(_sqlState('0A000')));
          await expectRecovers(query, '0A000');
          await expectRecovers(unparameterized, '0A000');
          // Statements dropped on the server (26000) are prepared again too.
          await conn.executeMaps('deallocate all');
          await expectLater(query(), throwsA(_sqlState('26000')));
          await expectRecovers(query, '26000');
          await expectRecovers(unparameterized, '26000');
        } finally {
          await conn.close();
        }
      }
    });
  });

  group('regressions', () {
    test('a parameter that fails to encode does not hang the connection',
        () async {
      final conn = await openRealConnectionOrSkip();
      if (conn == null) return;
      try {
        // Parse was written before the parameters were encoded: it stayed in
        // the write buffer, ahead of the next command, and the server's error
        // on it made it skip the next command (hang).
        await expectLater(
            conn.executeMaps('selec ?::jsonb',
                parameters: _params([
                  {'d': Object()}
                ])),
            throwsA(isA<JsonUnsupportedObjectError>()));
        await _expectInSync(conn);

        conn.enterPipelineMode();
        await expectLater(
            conn.executeQueryPipelined('selec ?::jsonb',
                parameters: _params([
                  {'d': Object()}
                ])),
            throwsA(isA<JsonUnsupportedObjectError>()));
        conn.exitPipelineMode();
        await _expectInSync(conn, 10);
      } finally {
        await conn.close();
      }
    });

    test('executeScalar raises an error that follows the first row', () async {
      final conn = await openRealConnectionOrSkip();
      if (conn == null) return;
      try {
        // close() drops errors: the first value of a failed statement was
        // returned.
        const failing = 'select 10 / (g - 3) from generate_series(1, 5) g';
        await expectLater(
            conn.executeScalar(failing), throwsA(_sqlState('22012')));
        await expectLater(conn.executeScalar('select 1; select 1 / 0'),
            throwsA(_sqlState('22012')));
        // Statements without rows before the query are skipped, as in
        // executeMaps.
        expect(
            await conn.executeScalar("set application_name to 'x'; select 5"),
            5);
        await _expectInSync(conn);
      } finally {
        await conn.close();
      }
    });

    test('executeNonQuery reads every statement', () async {
      final conn = await openRealConnectionOrSkip();
      if (conn == null) return;
      try {
        await conn.executeMaps('create temp table cov_nonquery (a int)');
        // Only the first statement was read: a later failure went unnoticed
        // and only its count was returned.
        expect(
            await conn
                .createCommand('insert into cov_nonquery values (1), (2); '
                    'insert into cov_nonquery values (3); '
                    'update cov_nonquery set a = a + 1')
                .executeNonQuery(),
            6);
        await expectLater(
            conn
                .createCommand('insert into cov_nonquery values (4); '
                    'insert into cov_nonquery_missing values (5)')
                .executeNonQuery(),
            throwsA(_sqlState('42P01')));
        expect(
            await conn.executeScalar('select count(*) from cov_nonquery'), 3);
        await _expectInSync(conn);
      } finally {
        await conn.close();
      }
    });

    test('rows of a statement after one without rows are returned', () async {
      final conn = await openRealConnectionOrSkip();
      if (conn == null) return;
      try {
        const sql = 'create temp table if not exists cov_multi (a int); '
            'insert into cov_multi values (1); '
            'select count(*)::int as n from cov_multi';
        // The rows after a first statement without rows were dropped.
        expect(await conn.executeMaps(sql), [
          {'n': 1}
        ]);
        expect(await conn.executeRows(sql), [
          [2]
        ]);
        expect(await conn.executeScalar(sql), 3);
        await _expectInSync(conn);
      } finally {
        await conn.close();
      }
    });

    test('prepared executeMaps raises errors after reading the response',
        () async {
      final conn = await openRealConnectionOrSkip();
      if (conn == null) return;
      try {
        final cmd = conn.createCommand(
            'select 10 / (g - ?) as v from generate_series(1, 3) g')
          ..parameters.addWithValue('p', 2);
        await cmd.prepare();
        for (var i = 0; i < 3; i++) {
          // The fast path threw with ReadyForQuery unread: the next command
          // returned [] and every later one the previous result.
          await expectLater(cmd.executeMaps(), throwsA(_sqlState('22012')));
          await _expectInSync(conn, i * 10);
        }
      } finally {
        await conn.close();
      }
    });

    test(r'$1 placeholders and @-prefixed parameter names', () async {
      final conn = await openRealConnectionOrSkip();
      if (conn == null) return;
      try {
        // `$1` bound no parameter (08P01 / 42P02).
        expect(
            await conn.executeMaps(r'select $1::int as a, $2::text as b',
                parameters: _params([5, 'x'])),
            [
              {'a': 5, 'b': 'x'}
            ]);
        final reader =
            await conn.query(r'select $1::int as v', substitutionValues: [6]);
        expect(await reader.readAllMaps(), [
          {'v': 6}
        ]);
        await reader.close();
        final prepared = conn.createCommand(r'select $1::int + 1 as v')
          ..parameters.addWithValue('x', 6);
        await prepared.prepare();
        expect(await prepared.executeScalar(), 7);
        // Npgsql-style names with their prefix were not found.
        final named = conn.createCommand('select @a::int + @b::int as v')
          ..parameters.addWithValue('@a', 1)
          ..parameters.addWithValue(':b', 2);
        expect(await named.executeScalar(), 3);
        // A `$1` inside a string or a dollar quote is not a placeholder.
        expect(
            await conn.executeScalar(r"select '$1' || $$ $2 $$ || ?::text",
                parameters: _params(['z'])),
            r'$1 $2 z');
      } finally {
        await conn.close();
      }
    });

    test('a batch whose first command fails leaves the connection in sync',
        () async {
      final conn = await openRealConnectionOrSkip();
      if (conn == null) return;
      try {
        for (final sql in [
          'select 1; select 2',
          'select * from cov_batch_missing',
          'select 1 / 0',
        ]) {
          final batch = conn.createBatch()
            ..createBatchCommand(sql)
            ..createBatchCommand('select 42');
          await expectLater(() async {
            final reader = await batch.executeReader();
            try {
              do {
                while (await reader.read()) {}
              } while (await reader.nextResult());
            } finally {
              await reader.close();
            }
          }(), throwsA(isA<PostgresBatchException>()));
          // ReadyForQuery was left unread: the next command returned null.
          await _expectInSync(conn);
        }
      } finally {
        await conn.close();
      }
    });

    test('notices and notifications reach DataSource connections', () async {
      final sender = await openRealConnectionOrSkip();
      if (sender == null) return;
      final dataSource =
          DpgsqlDataSource('${realConnectionString()};Maximum Pool Size=1');
      try {
        // They were wired only by open(): a pooled connection's streams
        // never emitted.
        final conn = await dataSource.openConnection();
        final notice = conn.notices.first;
        await conn.executeMaps(r"do $$ begin raise notice 'pooled'; end $$");
        expect((await notice.timeout(const Duration(seconds: 3))).messageText,
            'pooled');

        await conn.executeMaps('listen cov_pooled');
        final notification = conn.notifications.first;
        await sender.executeMaps("notify cov_pooled, 'hi'");
        expect((await notification.timeout(const Duration(seconds: 3))).payload,
            'hi');
        await conn.executeMaps('unlisten cov_pooled');
        await conn.close();

        // The next user of the connector does not see the previous user's
        // events, and gets its own.
        final next = await dataSource.openConnection();
        final previous = <String?>[];
        conn.notices.listen((n) => previous.add(n.messageText));
        final own = next.notices.first;
        await next.executeMaps(r"do $$ begin raise notice 'next'; end $$");
        expect((await own.timeout(const Duration(seconds: 3))).messageText,
            'next');
        expect(previous, isEmpty);
        await next.close();
      } finally {
        await dataSource.dispose();
        await sender.close();
      }
    });
  });
}
