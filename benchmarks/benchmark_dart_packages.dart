import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart' as pg3;
import 'package:postgres_fork/postgres.dart' as pg2;

Future<void> main() async {
  final config = _BenchConfig.fromEnvironment();
  final runner = switch (config.driverName) {
    'postgres_fork' => _PostgresForkRunner(config),
    'postgres_3' || 'postgres' => _Postgres3Runner(config),
    _ => throw ArgumentError(
        'BENCH_DRIVER_NAME must be postgres_fork or postgres_3'),
  };

  final result = await runner.run();
  stdout.writeln(jsonEncode(result));
}

abstract class _PackageRunner {
  _PackageRunner(this.config);

  final _BenchConfig config;

  Future<Map<String, dynamic>> run() async {
    final server = await serverInfo();
    final connect = await benchmarkConnect();

    await open();
    try {
      await ensureBenchmarkRows(config.tableName, config.maxRows);

      final selectOne = await benchmarkSelectOne();
      final parameter = await benchmarkParameter();
      final prepared = await benchmarkPrepared();
      final resultSetsDrain = <String, dynamic>{};
      final resultSetsSimple = <String, dynamic>{};
      final resultSetsMaps = <String, dynamic>{};
      final resultSets = <String, dynamic>{};

      for (final size in config.resultSetSizes) {
        resultSetsDrain['rows_$size'] = await benchmarkResultSetDrain(size);
        resultSetsSimple['rows_$size'] = await benchmarkResultSetSimple(size);
        resultSetsMaps['rows_$size'] = await benchmarkResultSetMaps(size);
        resultSets['rows_$size'] = await benchmarkResultSet(size);
      }

      return {
        'driver': config.driverName,
        'host': config.host,
        'port': config.port,
        'database': config.database,
        'secure': config.secure,
        'connect_mode': 'warm_auth_cache',
        'server': server,
        'connect_iterations': config.connectIterations,
        'connect_total_ms': connect.totalMs,
        'connect_avg_ms': connect.avgMs,
        'iterations': config.iterations,
        'warmup_iterations': config.warmupIterations,
        'resultset_warmup_iterations': config.resultSetWarmupIterations,
        'text_total_ms': selectOne.totalMs,
        'text_avg_ms': selectOne.avgMs,
        'text_ops_per_sec': selectOne.opsPerSec,
        'text_checksum': selectOne.checksum,
        'parameter_total_ms': parameter.totalMs,
        'parameter_avg_ms': parameter.avgMs,
        'parameter_ops_per_sec': parameter.opsPerSec,
        'parameter_checksum': parameter.checksum,
        'prepared_total_ms': prepared.totalMs,
        'prepared_avg_ms': prepared.avgMs,
        'prepared_ops_per_sec': prepared.opsPerSec,
        'prepared_checksum': prepared.checksum,
        'result_sets_drain': resultSetsDrain,
        'result_sets_simple': resultSetsSimple,
        'result_sets_maps': resultSetsMaps,
        'result_sets': resultSets,
      };
    } finally {
      await close();
    }
  }

  Future<void> open();

  Future<void> close();

  Future<Map<String, dynamic>> serverInfo();

  Future<_Metric> benchmarkConnect();

  Future<_Metric> benchmarkSelectOne();

  Future<_Metric> benchmarkParameter();

  Future<_Metric> benchmarkPrepared();

  Future<Map<String, dynamic>> benchmarkResultSet(int rowsPerQuery);

  Future<Map<String, dynamic>> benchmarkResultSetDrain(int rowsPerQuery);

  Future<Map<String, dynamic>> benchmarkResultSetSimple(int rowsPerQuery);

  Future<Map<String, dynamic>> benchmarkResultSetMaps(int rowsPerQuery);

  Future<void> ensureBenchmarkRows(String tableName, int targetRows);
}

class _Postgres3Runner extends _PackageRunner {
  _Postgres3Runner(super.config);

  pg3.Connection? _connection;

  pg3.Endpoint get _endpoint => pg3.Endpoint(
        host: config.host,
        port: config.port,
        database: config.database,
        username: config.user,
        password: config.password,
      );

  @override
  Future<void> open() async {
    _connection = await pg3.Connection.open(
      _endpoint,
      settings: pg3.ConnectionSettings(
        sslMode: config.secure ? pg3.SslMode.require : pg3.SslMode.disable,
      ),
    );
  }

  @override
  Future<void> close() async {
    await _connection?.close();
    _connection = null;
  }

  @override
  Future<Map<String, dynamic>> serverInfo() async {
    final conn = await pg3.Connection.open(
      _endpoint,
      settings: pg3.ConnectionSettings(
        sslMode: config.secure ? pg3.SslMode.require : pg3.SslMode.disable,
      ),
    );
    try {
      final result = await conn
          .execute('SELECT version(), current_setting(\'server_version_num\')');
      return {
        'version': result.first[0]?.toString(),
        'server_version_num': result.first[1]?.toString(),
      };
    } finally {
      await conn.close();
    }
  }

  @override
  Future<_Metric> benchmarkConnect() async {
    final sw = Stopwatch()..start();
    for (var i = 0; i < config.connectIterations; i++) {
      final conn = await pg3.Connection.open(
        _endpoint,
        settings: pg3.ConnectionSettings(
          sslMode: config.secure ? pg3.SslMode.require : pg3.SslMode.disable,
        ),
      );
      await conn.close();
    }
    sw.stop();
    return _Metric.fromElapsed(sw.elapsed, config.connectIterations, 0);
  }

  @override
  Future<_Metric> benchmarkSelectOne() async {
    var checksum = await _drainScalar('SELECT 1', config.warmupIterations);
    final sw = Stopwatch()..start();
    checksum += await _drainScalar('SELECT 1', config.iterations);
    sw.stop();
    return _Metric.fromElapsed(sw.elapsed, config.iterations, checksum);
  }

  @override
  Future<_Metric> benchmarkParameter() async {
    final sql = pg3.Sql.named('SELECT @a:int4 + @b:int4');
    var checksum = await _drainScalar(
      sql,
      config.warmupIterations,
      parameters: {'a': 40, 'b': 2},
    );
    final sw = Stopwatch()..start();
    checksum += await _drainScalar(
      sql,
      config.iterations,
      parameters: {'a': 40, 'b': 2},
    );
    sw.stop();
    return _Metric.fromElapsed(sw.elapsed, config.iterations, checksum);
  }

  @override
  Future<_Metric> benchmarkPrepared() async {
    final statement =
        await _connection!.prepare(pg3.Sql.named('SELECT @a:int4 + @b:int4'));
    try {
      var checksum = await _drainPreparedScalar(
        statement,
        config.warmupIterations,
        {'a': 40, 'b': 2},
      );
      final sw = Stopwatch()..start();
      checksum += await _drainPreparedScalar(
        statement,
        config.iterations,
        {'a': 40, 'b': 2},
      );
      sw.stop();
      return _Metric.fromElapsed(sw.elapsed, config.iterations, checksum);
    } finally {
      await statement.dispose();
    }
  }

  @override
  Future<Map<String, dynamic>> benchmarkResultSet(int rowsPerQuery) async {
    final statement = await _connection!.prepare(
      'SELECT id, name, amount, created_at, payload '
      'FROM ${config.tableName} ORDER BY id LIMIT $rowsPerQuery',
    );
    try {
      var checksum =
          await _drainRows(statement, config.resultSetWarmupIterations);
      final sw = Stopwatch()..start();
      checksum += await _drainRows(statement, config.resultSetIterations);
      sw.stop();
      return _resultSetMetric(
        elapsed: sw.elapsed,
        rowsPerQuery: rowsPerQuery,
        iterations: config.resultSetIterations,
        warmupIterations: config.resultSetWarmupIterations,
        checksum: checksum,
      );
    } finally {
      await statement.dispose();
    }
  }

  @override
  Future<Map<String, dynamic>> benchmarkResultSetDrain(int rowsPerQuery) async {
    final statement = await _connection!.prepare(
      'SELECT id, name, amount, created_at, payload '
      'FROM ${config.tableName} ORDER BY id LIMIT $rowsPerQuery',
    );
    try {
      var checksum =
          await _drainRowsOnly(statement, config.resultSetWarmupIterations);
      final sw = Stopwatch()..start();
      checksum += await _drainRowsOnly(statement, config.resultSetIterations);
      sw.stop();
      return _resultSetMetric(
        elapsed: sw.elapsed,
        rowsPerQuery: rowsPerQuery,
        iterations: config.resultSetIterations,
        warmupIterations: config.resultSetWarmupIterations,
        checksum: checksum,
      );
    } finally {
      await statement.dispose();
    }
  }

  @override
  Future<Map<String, dynamic>> benchmarkResultSetSimple(
      int rowsPerQuery) async {
    final statement = await _connection!.prepare(
      'SELECT id, name, payload FROM ${config.tableName} '
      'ORDER BY id LIMIT $rowsPerQuery',
    );
    try {
      var checksum =
          await _drainRowsSimple(statement, config.resultSetWarmupIterations);
      final sw = Stopwatch()..start();
      checksum += await _drainRowsSimple(statement, config.resultSetIterations);
      sw.stop();
      return _resultSetMetric(
        elapsed: sw.elapsed,
        rowsPerQuery: rowsPerQuery,
        iterations: config.resultSetIterations,
        warmupIterations: config.resultSetWarmupIterations,
        checksum: checksum,
      );
    } finally {
      await statement.dispose();
    }
  }

  @override
  Future<Map<String, dynamic>> benchmarkResultSetMaps(int rowsPerQuery) async {
    final statement = await _connection!.prepare(
      'SELECT id, name, amount, created_at, payload '
      'FROM ${config.tableName} ORDER BY id LIMIT $rowsPerQuery',
    );
    try {
      var checksum =
          await _drainRowsMap(statement, config.resultSetWarmupIterations);
      final sw = Stopwatch()..start();
      checksum += await _drainRowsMap(statement, config.resultSetIterations);
      sw.stop();
      return _resultSetMetric(
        elapsed: sw.elapsed,
        rowsPerQuery: rowsPerQuery,
        iterations: config.resultSetIterations,
        warmupIterations: config.resultSetWarmupIterations,
        checksum: checksum,
      );
    } finally {
      await statement.dispose();
    }
  }

  @override
  Future<void> ensureBenchmarkRows(String tableName, int targetRows) async {
    await _connection!.execute('''
CREATE TABLE IF NOT EXISTS $tableName (
  id INTEGER PRIMARY KEY,
  name VARCHAR(64) NOT NULL,
  amount NUMERIC(10, 2) NOT NULL,
  created_at TIMESTAMP NOT NULL,
  payload TEXT NOT NULL
)
''');

    final existing =
        await _connection!.execute('SELECT COUNT(*) FROM $tableName');
    if ((existing.first[0] as int) >= targetRows) return;

    await _connection!.execute('TRUNCATE TABLE $tableName');
    await _insertRows(
        (sql) => _connection!.execute(sql), tableName, targetRows);
  }

  Future<int> _drainScalar(
    Object sql,
    int iterations, {
    Object? parameters,
  }) async {
    var checksum = 0;
    for (var i = 0; i < iterations; i++) {
      final result = await _connection!.execute(sql, parameters: parameters);
      checksum += result.first[0] as int;
    }
    return checksum;
  }

  Future<int> _drainPreparedScalar(
    pg3.Statement statement,
    int iterations,
    Object? parameters,
  ) async {
    var checksum = 0;
    for (var i = 0; i < iterations; i++) {
      final result = await statement.run(parameters);
      checksum += result.first[0] as int;
    }
    return checksum;
  }

  Future<int> _drainRows(pg3.Statement statement, int iterations) async {
    var checksum = 0;
    for (var i = 0; i < iterations; i++) {
      final result = await statement.run(null);
      for (final row in result) {
        checksum += (row[0] as int) +
            row[1].toString().length +
            row[2].toString().length +
            row[3].toString().length +
            row[4].toString().length;
      }
    }
    return checksum;
  }

  Future<int> _drainRowsOnly(pg3.Statement statement, int iterations) async {
    var checksum = 0;
    for (var i = 0; i < iterations; i++) {
      final result = await statement.run(null);
      checksum += result.length;
    }
    return checksum;
  }

  Future<int> _drainRowsSimple(pg3.Statement statement, int iterations) async {
    var checksum = 0;
    for (var i = 0; i < iterations; i++) {
      final result = await statement.run(null);
      for (final row in result) {
        checksum += (row[0] as int) +
            row[1].toString().length +
            row[2].toString().length;
      }
    }
    return checksum;
  }

  Future<int> _drainRowsMap(pg3.Statement statement, int iterations) async {
    var checksum = 0;
    for (var i = 0; i < iterations; i++) {
      final result = await statement.run(null);
      for (final row in result) {
        final map = row.toColumnMap();
        checksum += (map['id'] as int) +
            map['name'].toString().length +
            map['amount'].toString().length +
            map['created_at'].toString().length +
            map['payload'].toString().length;
      }
    }
    return checksum;
  }
}

class _PostgresForkRunner extends _PackageRunner {
  _PostgresForkRunner(super.config);

  pg2.PostgreSQLConnection? _connection;

  pg2.PostgreSQLConnection _newConnection() => pg2.PostgreSQLConnection(
        config.host,
        config.port,
        config.database,
        username: config.user,
        password: config.password,
        useSSL: config.secure,
      );

  @override
  Future<void> open() async {
    _connection = _newConnection();
    await _connection!.open();
  }

  @override
  Future<void> close() async {
    await _connection?.close();
    _connection = null;
  }

  @override
  Future<Map<String, dynamic>> serverInfo() async {
    final conn = _newConnection();
    await conn.open();
    try {
      final result = await conn
          .query('SELECT version(), current_setting(\'server_version_num\')');
      return {
        'version': result.first[0]?.toString(),
        'server_version_num': result.first[1]?.toString(),
      };
    } finally {
      await conn.close();
    }
  }

  @override
  Future<_Metric> benchmarkConnect() async {
    final sw = Stopwatch()..start();
    for (var i = 0; i < config.connectIterations; i++) {
      final conn = _newConnection();
      await conn.open();
      await conn.close();
    }
    sw.stop();
    return _Metric.fromElapsed(sw.elapsed, config.connectIterations, 0);
  }

  @override
  Future<_Metric> benchmarkSelectOne() async {
    var checksum = await _drainScalar('SELECT 1', config.warmupIterations);
    final sw = Stopwatch()..start();
    checksum += await _drainScalar('SELECT 1', config.iterations);
    sw.stop();
    return _Metric.fromElapsed(sw.elapsed, config.iterations, checksum);
  }

  @override
  Future<_Metric> benchmarkParameter() async {
    const sql = 'SELECT CAST(@a AS int) + CAST(@b AS int)';
    const parameters = {'a': 40, 'b': 2};
    var checksum = await _drainScalar(
      sql,
      config.warmupIterations,
      substitutionValues: parameters,
    );
    final sw = Stopwatch()..start();
    checksum += await _drainScalar(
      sql,
      config.iterations,
      substitutionValues: parameters,
    );
    sw.stop();
    return _Metric.fromElapsed(sw.elapsed, config.iterations, checksum);
  }

  @override
  Future<_Metric> benchmarkPrepared() async {
    const sql = 'SELECT CAST(@a AS int) + CAST(@b AS int)';
    const parameters = {'a': 40, 'b': 2};
    var checksum = await _drainScalar(
      sql,
      config.warmupIterations,
      substitutionValues: parameters,
      allowReuse: true,
    );
    final sw = Stopwatch()..start();
    checksum += await _drainScalar(
      sql,
      config.iterations,
      substitutionValues: parameters,
      allowReuse: true,
    );
    sw.stop();
    return _Metric.fromElapsed(sw.elapsed, config.iterations, checksum);
  }

  @override
  Future<Map<String, dynamic>> benchmarkResultSet(int rowsPerQuery) async {
    final sql = 'SELECT id, name, amount, created_at, payload '
        'FROM ${config.tableName} ORDER BY id LIMIT $rowsPerQuery';
    var checksum =
        await _drainRows(sql, config.resultSetWarmupIterations, full: true);
    final sw = Stopwatch()..start();
    checksum += await _drainRows(sql, config.resultSetIterations, full: true);
    sw.stop();
    return _resultSetMetric(
      elapsed: sw.elapsed,
      rowsPerQuery: rowsPerQuery,
      iterations: config.resultSetIterations,
      warmupIterations: config.resultSetWarmupIterations,
      checksum: checksum,
    );
  }

  @override
  Future<Map<String, dynamic>> benchmarkResultSetDrain(int rowsPerQuery) async {
    final sql = 'SELECT id, name, amount, created_at, payload '
        'FROM ${config.tableName} ORDER BY id LIMIT $rowsPerQuery';
    var checksum = await _drainRowsOnly(sql, config.resultSetWarmupIterations);
    final sw = Stopwatch()..start();
    checksum += await _drainRowsOnly(sql, config.resultSetIterations);
    sw.stop();
    return _resultSetMetric(
      elapsed: sw.elapsed,
      rowsPerQuery: rowsPerQuery,
      iterations: config.resultSetIterations,
      warmupIterations: config.resultSetWarmupIterations,
      checksum: checksum,
    );
  }

  @override
  Future<Map<String, dynamic>> benchmarkResultSetSimple(
      int rowsPerQuery) async {
    final sql = 'SELECT id, name, payload FROM ${config.tableName} '
        'ORDER BY id LIMIT $rowsPerQuery';
    var checksum =
        await _drainRows(sql, config.resultSetWarmupIterations, full: false);
    final sw = Stopwatch()..start();
    checksum += await _drainRows(sql, config.resultSetIterations, full: false);
    sw.stop();
    return _resultSetMetric(
      elapsed: sw.elapsed,
      rowsPerQuery: rowsPerQuery,
      iterations: config.resultSetIterations,
      warmupIterations: config.resultSetWarmupIterations,
      checksum: checksum,
    );
  }

  @override
  Future<Map<String, dynamic>> benchmarkResultSetMaps(int rowsPerQuery) async {
    final sql = 'SELECT id, name, amount, created_at, payload '
        'FROM ${config.tableName} ORDER BY id LIMIT $rowsPerQuery';
    var checksum = await _drainRowsMap(sql, config.resultSetWarmupIterations);
    final sw = Stopwatch()..start();
    checksum += await _drainRowsMap(sql, config.resultSetIterations);
    sw.stop();
    return _resultSetMetric(
      elapsed: sw.elapsed,
      rowsPerQuery: rowsPerQuery,
      iterations: config.resultSetIterations,
      warmupIterations: config.resultSetWarmupIterations,
      checksum: checksum,
    );
  }

  @override
  Future<void> ensureBenchmarkRows(String tableName, int targetRows) async {
    await _connection!.execute('''
CREATE TABLE IF NOT EXISTS $tableName (
  id INTEGER PRIMARY KEY,
  name VARCHAR(64) NOT NULL,
  amount NUMERIC(10, 2) NOT NULL,
  created_at TIMESTAMP NOT NULL,
  payload TEXT NOT NULL
)
''');

    final existing =
        await _connection!.query('SELECT COUNT(*) FROM $tableName');
    if ((existing.first[0] as int) >= targetRows) return;

    await _connection!.execute('TRUNCATE TABLE $tableName');
    await _insertRows(
        (sql) => _connection!.execute(sql), tableName, targetRows);
  }

  Future<int> _drainScalar(
    String sql,
    int iterations, {
    dynamic substitutionValues,
    bool allowReuse = true,
  }) async {
    var checksum = 0;
    for (var i = 0; i < iterations; i++) {
      final result = await _connection!.query(
        sql,
        substitutionValues: substitutionValues,
        allowReuse: allowReuse,
      );
      checksum += result.first[0] as int;
    }
    return checksum;
  }

  Future<int> _drainRows(String sql, int iterations,
      {required bool full}) async {
    var checksum = 0;
    for (var i = 0; i < iterations; i++) {
      final result = await _connection!.query(sql, allowReuse: true);
      for (final row in result) {
        if (full) {
          checksum += (row[0] as int) +
              row[1].toString().length +
              row[2].toString().length +
              row[3].toString().length +
              row[4].toString().length;
        } else {
          checksum += (row[0] as int) +
              row[1].toString().length +
              row[2].toString().length;
        }
      }
    }
    return checksum;
  }

  Future<int> _drainRowsOnly(String sql, int iterations) async {
    var checksum = 0;
    for (var i = 0; i < iterations; i++) {
      final result = await _connection!.query(sql, allowReuse: true);
      checksum += result.length;
    }
    return checksum;
  }

  Future<int> _drainRowsMap(String sql, int iterations) async {
    var checksum = 0;
    for (var i = 0; i < iterations; i++) {
      final result = await _connection!.query(sql, allowReuse: true);
      for (final row in result) {
        final map = row.toColumnMap();
        checksum += (map['id'] as int) +
            map['name'].toString().length +
            map['amount'].toString().length +
            map['created_at'].toString().length +
            map['payload'].toString().length;
      }
    }
    return checksum;
  }
}

Future<void> _insertRows(
  Future<Object?> Function(String sql) execute,
  String tableName,
  int targetRows,
) async {
  const batchSize = 500;
  for (var start = 1; start <= targetRows; start += batchSize) {
    final end = (start + batchSize - 1) > targetRows
        ? targetRows
        : start + batchSize - 1;
    final values = <String>[];
    for (var id = start; id <= end; id++) {
      final cents = (id % 100).toString().padLeft(2, '0');
      final second = (id % 60).toString().padLeft(2, '0');
      final payloadId = id.toString().padLeft(5, '0');
      values.add(
        "($id,'name_$id',$id.$cents,'2024-01-01 12:34:$second',"
        "'payload_${payloadId}_abcdefghijklmnopqrstuvwxyz')",
      );
    }

    await execute(
      'INSERT INTO $tableName (id, name, amount, created_at, payload) '
      'VALUES ${values.join(',')}',
    );
  }
}

Map<String, dynamic> _resultSetMetric({
  required Duration elapsed,
  required int rowsPerQuery,
  required int iterations,
  required int warmupIterations,
  required int checksum,
}) {
  final elapsedSeconds =
      elapsed.inMicroseconds / Duration.microsecondsPerSecond;
  final rowCount = rowsPerQuery * iterations;

  return {
    'rows_per_query': rowsPerQuery,
    'iterations': iterations,
    'warmup_iterations': warmupIterations,
    'total_ms': elapsed.inMicroseconds / 1000.0,
    'avg_ms': (elapsed.inMicroseconds / 1000.0) / iterations,
    'queries_per_sec': iterations / elapsedSeconds,
    'rows_per_sec': rowCount / elapsedSeconds,
    'checksum': checksum,
  };
}

class _BenchConfig {
  _BenchConfig({
    required this.driverName,
    required this.host,
    required this.port,
    required this.user,
    required this.password,
    required this.database,
    required this.secure,
    required this.tableName,
    required this.iterations,
    required this.connectIterations,
    required this.warmupIterations,
    required this.resultSetIterations,
    required this.resultSetWarmupIterations,
    required this.resultSetSizes,
  });

  factory _BenchConfig.fromEnvironment() {
    final resultSetSizes = _env('BENCH_RESULTSET_SIZES', '10,1000,3000,10000')
        .split(',')
        .map((s) => int.tryParse(s.trim()))
        .whereType<int>()
        .where((i) => i > 0)
        .toList(growable: false);

    return _BenchConfig(
      driverName: _env('BENCH_DRIVER_NAME', 'postgres_3'),
      host: _env('PGHOST', _env('POSTGRES_HOST', '127.0.0.1')),
      port: _envInt('PGPORT', _envInt('POSTGRES_PORT', 5432)),
      user: _env('PGUSER', _env('POSTGRES_USER', 'dart')),
      password: _env('PGPASSWORD', _env('POSTGRES_PASSWORD', 'dart')),
      database: _env('PGDATABASE', _env('POSTGRES_DATABASE', 'dart_test')),
      secure: _envBool('POSTGRES_SECURE', false),
      tableName: _env('BENCH_TABLE', 'bench_rows_postgres_3'),
      iterations: _envInt('BENCH_ITERATIONS', 2000),
      connectIterations: _envInt('BENCH_CONNECT_ITERATIONS', 25),
      warmupIterations: _envInt('BENCH_WARMUP_ITERATIONS', 200),
      resultSetIterations: _envInt('BENCH_RESULTSET_ITERATIONS', 20),
      resultSetWarmupIterations:
          _envInt('BENCH_RESULTSET_WARMUP_ITERATIONS', 5),
      resultSetSizes:
          resultSetSizes.isEmpty ? const [10, 1000, 10000] : resultSetSizes,
    );
  }

  final String driverName;
  final String host;
  final int port;
  final String user;
  final String password;
  final String database;
  final bool secure;
  final String tableName;
  final int iterations;
  final int connectIterations;
  final int warmupIterations;
  final int resultSetIterations;
  final int resultSetWarmupIterations;
  final List<int> resultSetSizes;

  int get maxRows => resultSetSizes.reduce((a, b) => a > b ? a : b);
}

class _Metric {
  _Metric({
    required this.totalMs,
    required this.avgMs,
    required this.opsPerSec,
    required this.checksum,
  });

  factory _Metric.fromElapsed(Duration elapsed, int iterations, int checksum) {
    final totalMs = elapsed.inMicroseconds / 1000.0;
    final seconds = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    return _Metric(
      totalMs: totalMs,
      avgMs: totalMs / iterations,
      opsPerSec: iterations / seconds,
      checksum: checksum,
    );
  }

  final double totalMs;
  final double avgMs;
  final double opsPerSec;
  final int checksum;
}

String _env(String key, String fallback) {
  final value = Platform.environment[key]?.trim();
  return value == null || value.isEmpty ? fallback : value;
}

int _envInt(String key, int fallback) {
  final value = int.tryParse(Platform.environment[key]?.trim() ?? '');
  return value == null || value <= 0 ? fallback : value;
}

bool _envBool(String key, bool fallback) {
  final value = Platform.environment[key]?.trim().toLowerCase();
  if (value == null || value.isEmpty) return fallback;
  return const {'1', 'true', 'yes', 'on'}.contains(value);
}
