// Coverage matrix against a real server: every entry point x statement kind x
// placeholder style, each executed 6 times (so the auto-prepare and prepared
// fast paths run), on three connection setups. After every execution the
// next command must return its own result: a response left partly unread
// shifts every later result, the classic bug of this driver. Rows,
// recordsAffected and notices are checked too.

import 'dart:async';

import 'package:dpgsql/dpgsql.dart';
import 'package:test/test.dart';

import 'test_config.dart';

const _repetitions = 6;

enum _Style { none, question, named, numbered }

class _Kind {
  const _Kind(
    this.name,
    this.sql, {
    this.value,
    this.rows = const [],
    this.affected,
    this.error,
    this.notice,
    this.multiStatement = false,
  });

  final String name;

  /// `{p}` is the parameter (or its literal with [_Style.none]).
  final String sql;
  final Object? value;
  final List<List<Object?>> rows;

  /// recordsAffected reported by readers; `null`: not checked.
  final int? affected;

  /// Expected SQLSTATE; `null`: the statement succeeds.
  final String? error;

  /// A notice expected on every execution: `sqlState` or `message:` text.
  final String? notice;

  /// Fails with 42601 through the extended protocol.
  final bool multiStatement;

  bool get parameterized => sql.contains('{p}');
}

const _kinds = <_Kind>[
  _Kind('select rows',
      'select g as v from generate_series(1, 3) g where g >= {p}::int order by g',
      value: 1,
      rows: [
        [1],
        [2],
        [3]
      ],
      affected: 3),
  _Kind('select 0 rows',
      'select g as v from generate_series(1, 3) g where g > {p}::int',
      value: 10, affected: 0),
  _Kind('insert', 'insert into cov_matrix (v) values ({p}::int)',
      value: 7, affected: 1),
  _Kind('insert returning',
      'insert into cov_matrix (v) values ({p}::int) returning v',
      value: 8,
      rows: [
        [8]
      ],
      affected: 1),
  _Kind('update', 'update cov_matrix set w = w + 1 where v = {p}::int',
      value: 100, affected: 1),
  _Kind('update returning',
      'update cov_matrix set w = w + 1 where v = {p}::int returning v',
      value: 100,
      rows: [
        [100]
      ],
      affected: 1),
  _Kind('delete 0 rows', 'delete from cov_matrix where v = {p}::int',
      value: -1, affected: 0),
  // Deletes one of the rows the 'insert' kind added just before.
  _Kind(
      'delete returning',
      'delete from cov_matrix where id = '
          '(select max(id) from cov_matrix where v = {p}::int) returning v',
      value: 7,
      rows: [
        [7]
      ],
      affected: 1),
  _Kind('ddl', 'create temp table if not exists cov_matrix_ddl (a int)',
      affected: 0),
  _Kind('set', "set application_name to 'cov_matrix'", affected: 0),
  _Kind(
      'do with raise notice', r"do $$ begin raise notice 'cov-notice'; end $$",
      affected: 0, notice: 'message:cov-notice'),
  _Kind('drop if exists (notice)', 'drop table if exists cov_matrix_absent',
      affected: 0, notice: '00000'),
  _Kind('multi-statement', "set application_name to 'cov_multi'; select 1 as v",
      rows: [
        [1]
      ],
      affected: 1,
      multiStatement: true),
  _Kind('error before RowDescription',
      'select v from cov_matrix_missing where v = {p}::int',
      value: 1, error: '42P01'),
  _Kind('error after some rows',
      'select 10 / (g - {p}::int) as v from generate_series(1, 5) g',
      value: 3, error: '22012'),
  _Kind('invalid parameter value', 'select {p}::int as v',
      value: 'abc', error: '22P02'),
];

String _render(_Kind kind, _Style style) => kind.sql.replaceAll(
    '{p}',
    switch (style) {
      _Style.none => kind.value is String ? "'${kind.value}'" : '${kind.value}',
      _Style.question => '?',
      _Style.named => '@v',
      _Style.numbered => r'$1',
    });

DpgsqlParameterCollection? _parameters(_Kind kind, _Style style) =>
    style == _Style.none || !kind.parameterized
        ? null
        : (DpgsqlParameterCollection()..add(DpgsqlParameter('v', kind.value)));

class _Outcome {
  _Outcome(this.rows, [this.affected]);

  final List<List<Object?>> rows;
  final int? affected;
}

Future<_Outcome> _readAll(DpgsqlDataReader reader) async {
  final rows = <List<Object?>>[];
  var affected = 0;
  try {
    do {
      while (await reader.read()) {
        rows.add([for (var i = 0; i < reader.fieldCount; i++) reader[i]]);
      }
      affected = reader.recordsAffected;
    } while (await reader.nextResult());
  } finally {
    await reader.close();
  }
  return _Outcome(rows, affected);
}

List<List<Object?>> _pgRows(List<PgRow> rows) => [
      for (final row in rows)
        [for (var i = 0; i < row.columnCount; i++) row.getInt(i)]
    ];

class _Context {
  _Context(this.conn, this.dataSource, this.notices);

  final DpgsqlConnection conn;
  final DpgsqlDataSource dataSource;
  final List<ErrorOrNoticeMessage> notices;
  var _names = 0;

  String nextName() => 'cov_stmt_${_names++}';

  /// Opens a pooled connection whose notices are collected too.
  Future<DpgsqlConnection> pooled() async {
    final connection = await dataSource.openConnection();
    connection.notices.listen(notices.add);
    return connection;
  }
}

/// Prepares one statement and returns the function that executes it.
typedef _Setup = Future<Future<_Outcome> Function()> Function(
    _Context ctx, String sql, DpgsqlParameterCollection? parameters);

class _Entry {
  const _Entry(
    this.name,
    this.setup, {
    this.extended = false,
    this.styles = _Style.values,
    this.reportsAffected = false,
    this.rowsChecked = true,
    this.scalar = false,
    this.trailingRows = const [],
    this.pooled = false,
  });

  final String name;
  final _Setup setup;

  /// Always uses the extended protocol (no multi-statement text).
  final bool extended;
  final List<_Style> styles;

  /// [_Outcome.affected] is compared with [_Kind.affected].
  final bool reportsAffected;
  final bool rowsChecked;

  /// Returns the first value only.
  final bool scalar;

  /// Rows the entry adds after the statement's own (a second command).
  final List<List<Object?>> trailingRows;

  /// Runs on DataSource connections: the sentinel uses one too.
  final bool pooled;
}

DpgsqlCommand _command(
    DpgsqlConnection conn, String sql, DpgsqlParameterCollection? parameters) {
  final cmd = conn.createCommand(sql);
  if (parameters != null) cmd.parameters.addAll(parameters);
  return cmd;
}

Object? _substitution(DpgsqlParameterCollection? parameters, String sql) {
  if (parameters == null) return null;
  final value = parameters.single.value;
  return sql.contains('@v') ? {'v': value} : [value];
}

List<_Entry> _commandEntries({required bool prepared}) {
  final suffix = prepared ? ' (prepared)' : '';
  Future<DpgsqlCommand> make(
      _Context ctx, String sql, DpgsqlParameterCollection? p) async {
    final cmd = _command(ctx.conn, sql, p);
    if (prepared) await cmd.prepare();
    return cmd;
  }

  return [
    _Entry('DpgsqlCommand.executeReader$suffix', (ctx, sql, p) async {
      final cmd = await make(ctx, sql, p);
      return () async => _readAll(await cmd.executeReader());
    }, extended: prepared, reportsAffected: true),
    _Entry('DpgsqlCommand.executeNonQuery$suffix', (ctx, sql, p) async {
      final cmd = await make(ctx, sql, p);
      return () async => _Outcome(const [], await cmd.executeNonQuery());
    }, extended: prepared, reportsAffected: true, rowsChecked: false),
    _Entry('DpgsqlCommand.executeScalar$suffix', (ctx, sql, p) async {
      final cmd = await make(ctx, sql, p);
      return () async {
        final value = await cmd.executeScalar();
        return _Outcome(value == null
            ? []
            : [
                [value]
              ]);
      };
    }, extended: prepared, scalar: true),
    _Entry('DpgsqlCommand.executeMaps$suffix', (ctx, sql, p) async {
      final cmd = await make(ctx, sql, p);
      return () async => _Outcome(
          [for (final row in await cmd.executeMaps()) row.values.toList()]);
    }, extended: prepared),
    _Entry('DpgsqlCommand.executeRows$suffix', (ctx, sql, p) async {
      final cmd = await make(ctx, sql, p);
      return () async => _Outcome(await cmd.executeRows());
    }, extended: prepared),
  ];
}

final _entries = <_Entry>[
  _Entry('DpgsqlConnection.executeRows', (ctx, sql, p) async {
    return () async => _Outcome(await ctx.conn.executeRows(sql, parameters: p));
  }),
  _Entry('DpgsqlConnection.executeMaps', (ctx, sql, p) async {
    return () async => _Outcome([
          for (final row in await ctx.conn.executeMaps(sql, parameters: p))
            row.values.toList()
        ]);
  }),
  _Entry('DpgsqlConnection.executeScalar', (ctx, sql, p) async {
    return () async {
      final value = await ctx.conn.executeScalar(sql, parameters: p);
      return _Outcome(value == null
          ? []
          : [
              [value]
            ]);
    };
  }, scalar: true),
  _Entry('DpgsqlConnection.executeReader', (ctx, sql, p) async {
    return () async =>
        _readAll(await ctx.conn.executeReader(sql, parameters: p));
  }, reportsAffected: true),
  _Entry('DpgsqlConnection.executePgRows', (ctx, sql, p) async {
    return () async =>
        _Outcome(_pgRows(await ctx.conn.executePgRows(sql, parameters: p)));
  }, extended: true),
  _Entry('DpgsqlConnection.forEachPgRow', (ctx, sql, p) async {
    return () async {
      final rows = <List<Object?>>[];
      await ctx.conn.forEachPgRow(sql, (row) async {
        await Future<void>.delayed(Duration.zero);
        rows.add([for (var i = 0; i < row.columnCount; i++) row.getInt(i)]);
      }, parameters: p);
      return _Outcome(rows);
    };
  }, extended: true),
  _Entry('DpgsqlConnection.forEachPgRowSync', (ctx, sql, p) async {
    return () async {
      final rows = <List<Object?>>[];
      await ctx.conn.forEachPgRowSync(sql, (row) {
        rows.add([for (var i = 0; i < row.columnCount; i++) row.getInt(i)]);
      }, parameters: p);
      return _Outcome(rows);
    };
  }, extended: true),
  _Entry('DpgsqlConnection.query', (ctx, sql, p) async {
    return () async => _readAll(
        await ctx.conn.query(sql, substitutionValues: _substitution(p, sql)));
  }, reportsAffected: true),
  _Entry('DpgsqlConnection.prepare + statementName', (ctx, sql, p) async {
    final name = ctx.nextName();
    await ctx.conn.prepare(sql, name, p ?? DpgsqlParameterCollection());
    return () async => _Outcome(
        await ctx.conn.executeRows(sql, statementName: name, parameters: p));
  }, extended: true, styles: const [_Style.none, _Style.numbered]),
  ..._commandEntries(prepared: false),
  ..._commandEntries(prepared: true),
  _Entry('DpgsqlBatch', (ctx, sql, p) async {
    final batch = ctx.conn.createBatch();
    final command = batch.createBatchCommand(sql);
    if (p != null) command.parameters.addAll(p);
    batch.createBatchCommand('select 42 as v');
    return () async => _readAll(await batch.executeReader());
  }, extended: true, trailingRows: const [
    [42]
  ]),
  _Entry('executeCommandsPipelined', (ctx, sql, p) async {
    return () async => _readAll(await ctx.conn.executeCommandsPipelined([
          _command(ctx.conn, sql, p),
          ctx.conn.createCommand('select 42 as v'),
        ]));
  }, extended: true, trailingRows: const [
    [42]
  ]),
  _Entry('DpgsqlDataSource connection', (ctx, sql, p) async {
    return () async {
      final pooled = await ctx.pooled();
      try {
        return _Outcome(await pooled.executeRows(sql, parameters: p));
      } finally {
        await pooled.close();
      }
    };
  }, pooled: true),
  // Each execution in its own savepoint: an error is rolled back to it and
  // the transaction must still work, then the error ends the transaction.
  _Entry('runInTransaction + savepoint', (ctx, sql, p) async {
    return () => ctx.conn.runInTransaction((tx) async {
          await tx.save('cov_sp');
          try {
            final rows = await ctx.conn.executeRows(sql, parameters: p);
            await tx.release('cov_sp');
            return _Outcome(rows);
          } catch (_) {
            await tx.rollbackTo('cov_sp');
            expect(await ctx.conn.executeScalar('select 1'), 1,
                reason: 'the transaction works after rollbackTo');
            rethrow;
          }
        });
  }),
];

class _Variant {
  const _Variant(this.name, this.options, {this.extended = false});

  final String name;
  final String options;

  /// Commands without parameters use the extended protocol too.
  final bool extended;
}

const _variants = [
  _Variant('simple protocol', ''),
  _Variant('auto-prepare', 'Max Auto Prepare=20;Auto Prepare Min Usages=2'),
  _Variant(
      'extended protocol + auto-prepare',
      'Use Extended Query For Unparameterized Commands=true;'
          'Max Auto Prepare=20;Auto Prepare Min Usages=2',
      extended: true),
];

Future<void> _runKind(_Context ctx, _Variant variant, _Entry entry, _Kind kind,
    _Style style, Future<void> Function(String reason) sentinel) async {
  final sql = _render(kind, style);
  final parameters = _parameters(kind, style);
  final label = '${entry.name} / ${kind.name} / ${style.name}';
  final extended = variant.extended || entry.extended || parameters != null;
  final expectedError = kind.multiStatement && extended ? '42601' : kind.error;
  final expectedRows = [
    if (entry.scalar)
      ...kind.rows.take(1).map((row) => [row.first])
    else
      ...kind.rows,
    if (!entry.scalar) ...entry.trailingRows,
  ];

  Future<_Outcome> Function()? execute;
  Object? setupError;
  try {
    execute = await entry.setup(ctx, sql, parameters);
  } catch (error) {
    setupError = error;
  }

  for (var round = 0; round < _repetitions; round++) {
    ctx.notices.clear();
    _Outcome? outcome;
    Object? error = setupError;
    if (execute != null) {
      try {
        outcome = await execute().timeout(const Duration(seconds: 10));
      } catch (e) {
        error = e;
      }
    }
    final reason = '$label (round $round)';

    if (expectedError != null) {
      expect(error, isA<PostgresException>(), reason: reason);
      expect((error as PostgresException).sqlState, expectedError,
          reason: reason);
    } else {
      if (error != null) fail('$reason: unexpected $error');
      if (entry.rowsChecked) {
        expect(outcome!.rows, expectedRows, reason: reason);
      }
      if (entry.reportsAffected && kind.affected != null) {
        expect(outcome!.affected, kind.affected, reason: '$reason (affected)');
      }
      final notice = kind.notice;
      if (notice != null) {
        await Future<void>.delayed(Duration.zero);
        expect(
            ctx.notices,
            contains(notice.startsWith('message:')
                ? isA<ErrorOrNoticeMessage>().having((n) => n.messageText,
                    'messageText', notice.substring('message:'.length))
                : isA<ErrorOrNoticeMessage>()
                    .having((n) => n.sqlState, 'sqlState', notice)),
            reason: '$reason (notice)');
      }
    }
    await sentinel(reason);
    if (setupError != null) break;
  }
}

void main() {
  late String baseConnectionString;
  var available = true;

  setUpAll(() async {
    final conn = await openRealConnectionOrSkip();
    if (conn == null) {
      available = false;
      return;
    }
    baseConnectionString = realConnectionString();
    await conn.executeMaps('drop table if exists cov_matrix');
    await conn.executeMaps('create table cov_matrix '
        '(id serial primary key, v int, w int not null default 0)');
    await conn.executeMaps('insert into cov_matrix (v) values (100)');
    await conn.close();
  });

  tearDownAll(() async {
    if (!available) return;
    final conn = await openRealConnectionOrSkip();
    await conn?.executeMaps('drop table if exists cov_matrix');
    await conn?.close();
  });

  for (final variant in _variants) {
    group(variant.name, () {
      for (final entry in _entries) {
        test(entry.name, () async {
          if (!available) return;
          final options = variant.options;
          final connectionString = options.isEmpty
              ? baseConnectionString
              : '$baseConnectionString;$options';
          final conn = DpgsqlConnection(connectionString);
          await conn.open();
          final dataSource =
              DpgsqlDataSource('$connectionString;Maximum Pool Size=1');
          final ctx = _Context(conn, dataSource, []);
          conn.notices.listen(ctx.notices.add);
          var sentinelValue = 0;

          Future<void> sentinel(String reason) async {
            final value = ++sentinelValue;
            final sql = 'select $value::int as sentinel';
            if (entry.pooled) {
              final pooled = await ctx.pooled();
              try {
                expect(await pooled.executeScalar(sql), value,
                    reason: '$reason: next command on the pooled connection');
              } finally {
                await pooled.close();
              }
            } else {
              expect(await conn.executeScalar(sql), value,
                  reason: '$reason: next command');
              expect(
                  await conn.executeMaps(sql),
                  [
                    {'sentinel': value}
                  ],
                  reason: '$reason: next command (maps)');
            }
          }

          try {
            for (final style in entry.styles) {
              for (final kind in _kinds) {
                if (!kind.parameterized && style != _Style.none) continue;
                await _runKind(ctx, variant, entry, kind, style, sentinel);
              }
            }
          } finally {
            await dataSource.dispose();
            await conn.close();
          }
        }, timeout: const Timeout(Duration(minutes: 3)));
      }
    });
  }
}
