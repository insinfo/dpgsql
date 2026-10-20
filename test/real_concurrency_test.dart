// Concurrent callers of one DpgsqlConnection (queueConcurrentCalls, the
// default): commands wait for their turn instead of failing, a reader or a
// COPY keeps the turn until it is closed, and commands from outside a
// runInTransaction callback wait for the transaction instead of running
// inside it.

import 'dart:async';

import 'package:dpgsql/dpgsql.dart';
import 'package:test/test.dart';

import 'test_config.dart';

Future<List<String>> _names(DpgsqlConnection c) async => [
      for (final row
          in await c.executeMaps('select name from dpgsql_queue order by id'))
        row['name'] as String,
    ];

Future<void> _add(DpgsqlConnection c, String name) =>
    c.executeMaps("insert into dpgsql_queue (name) values ('$name')");

void main() {
  late DpgsqlConnection conn;
  var available = true;

  setUp(() async {
    final opened = await openRealConnectionOrSkip();
    if (opened == null) {
      available = false;
      return;
    }
    conn = opened;
    await conn.executeMaps('drop table if exists dpgsql_queue');
    await conn.executeMaps(
        'create table dpgsql_queue (id serial primary key, name text)');
  });
  tearDown(() async {
    if (!available) return;
    await conn.executeMaps('drop table if exists dpgsql_queue');
    await conn.close();
  });

  test('concurrent commands run one at a time, in call order', () async {
    if (!available) return;
    final results = await Future.wait([
      for (var i = 0; i < 30; i++)
        switch (i % 3) {
          0 => conn.executeScalar('select $i'),
          1 => conn.executeMaps('select $i as v').then((r) => r.single['v']),
          _ => conn.executeRows('select $i').then((r) => r.single.single),
        },
    ]);
    expect(results, List.generate(30, (i) => i));

    final order = <int>[];
    await Future.wait([
      for (var i = 0; i < 10; i++) _add(conn, 'n$i').then((_) => order.add(i)),
    ]);
    expect(order, List.generate(10, (i) => i));
    expect(await _names(conn), List.generate(10, (i) => 'n$i'));
  });

  test('an open reader keeps the turn until it is closed', () async {
    if (!available) return;
    final reader =
        await conn.executeReader('select g from generate_series(1, 3) g');
    var nextDone = false;
    final next = conn.executeScalar('select 42').then((v) {
      nextDone = true;
      return v;
    });
    final values = <Object?>[];
    while (await reader.read()) {
      values.add(reader.getValue(0));
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(nextDone, isFalse);
    await reader.close();
    expect(await next, 42);
    expect(values, [1, 2, 3]);
  });

  test('a command from outside waits for the transaction and stays outside it',
      () async {
    if (!available) return;
    final entered = Completer<void>();
    final transaction = conn.runInTransaction((tx) async {
      await _add(conn, 'tx');
      entered.complete();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      throw StateError('roll back');
    });
    await entered.future;
    final outside = _add(conn, 'outside');
    await expectLater(transaction, throwsStateError);
    await outside;
    expect(await _names(conn), ['outside']);
  });

  test('a read from outside sees the transaction only after the commit',
      () async {
    if (!available) return;
    final entered = Completer<void>();
    var committed = false;
    final transaction = conn.runInTransaction((tx) async {
      await _add(conn, 'a');
      entered.complete();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      committed = true;
      return 'done';
    });
    await entered.future;
    final names = await _names(conn);
    expect(committed, isTrue);
    expect(names, ['a']);
    expect(await transaction, 'done');
  });

  test('concurrent commands inside the callback run in the transaction',
      () async {
    if (!available) return;
    await expectLater(conn.runInTransaction((tx) async {
      await Future.wait([for (var i = 0; i < 8; i++) _add(conn, 't$i')]);
      expect(await _names(conn), hasLength(8));
      throw StateError('roll back');
    }), throwsStateError);
    expect(await _names(conn), isEmpty);
  });

  test('concurrent transactions run one after the other', () async {
    if (!available) return;
    final log = <String>[];
    await Future.wait([
      for (var i = 0; i < 4; i++)
        conn.runInTransaction((tx) async {
          log.add('begin $i');
          await _add(conn, 'x$i');
          await Future<void>.delayed(const Duration(milliseconds: 20));
          log.add('end $i');
        }),
    ]);
    expect(log, [
      for (var i = 0; i < 4; i++) ...['begin $i', 'end $i'],
    ]);
    expect(await _names(conn), ['x0', 'x1', 'x2', 'x3']);
  });

  test('the callback may commit or roll back itself', () async {
    if (!available) return;
    await conn.runInTransaction((tx) async {
      await _add(conn, 'kept');
      await tx.commit();
    });
    await conn.runInTransaction((tx) async {
      await _add(conn, 'dropped');
      await tx.rollback();
    });
    expect(await _names(conn), ['kept']);
    expect(conn.hasActiveTransaction, isFalse);
  });

  test('runInTransaction inside its own callback is rejected', () async {
    if (!available) return;
    await expectLater(
        conn.runInTransaction((tx) => conn.runInTransaction((_) async => 1)),
        throwsStateError);
    expect(conn.hasActiveTransaction, isFalse);
    expect(await conn.executeScalar('select 1'), 1);
  });

  test('a COPY keeps the turn until it is closed', () async {
    if (!available) return;
    final exporter = await conn
        .beginRawBinaryCopy('copy (select 1 union all select 2) to stdout');
    final next = conn.executeScalar('select 7');
    // Reading to the end completes and releases the COPY.
    final bytes = await exporter.readAllBytes();
    expect(bytes, isNotEmpty);
    expect(await next, 7);
  });

  test('queueConcurrentCalls: false rejects a second transaction', () async {
    if (!available) return;
    conn.queueConcurrentCalls = false;
    final transaction = conn.runInTransaction(
        (tx) => Future<void>.delayed(const Duration(milliseconds: 50)));
    await expectLater(conn.runInTransaction((tx) async {}), throwsStateError);
    await transaction;
    conn.queueConcurrentCalls = true;
  });
}
