import 'dart:convert';
import 'dart:io';

import 'package:dpgsql/dpgsql.dart';

Future<void> main() async {
  final config = _BenchConfig.fromEnvironment();
  final connectionString = config.connectionString;

  final server = await _serverInfo(connectionString);

  final connect = await _benchmarkConnect(connectionString, config);

  final connection = DpgsqlConnection(connectionString);
  await connection.open();
  try {
    await _ensureBenchmarkRows(connection, config.tableName, config.maxRows);

    final selectOne = await _benchmarkSelectOne(connection, config);
    final parameter = await _benchmarkParameter(connection, config);
    final prepared = await _benchmarkPrepared(connection, config);
    final resultSets = <String, dynamic>{};
    final resultSetsDrain = <String, dynamic>{};
    final resultSetsSimple = <String, dynamic>{};

    for (final size in config.resultSetSizes) {
      resultSetsDrain['rows_$size'] = await _benchmarkResultSetDrain(
        connection,
        config.tableName,
        size,
        config,
      );
      resultSetsSimple['rows_$size'] = await _benchmarkResultSetSimple(
        connection,
        config.tableName,
        size,
        config,
      );
      resultSets['rows_$size'] = await _benchmarkResultSet(
        connection,
        config.tableName,
        size,
        config,
      );
    }

    stdout.writeln(jsonEncode({
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
      'result_sets': resultSets,
    }));
  } finally {
    await connection.close();
  }
}

Future<Map<String, dynamic>> _serverInfo(String connectionString) async {
  final connection = DpgsqlConnection(connectionString);
  await connection.open();
  try {
    final command = DpgsqlCommand(
      'SELECT version(), current_setting(\'server_version_num\')',
      connection,
    );
    final reader = await command.executeReader();
    try {
      if (await reader.read()) {
        return {
          'version': reader.getValue(0)?.toString(),
          'server_version_num': reader.getValue(1)?.toString(),
        };
      }
      return {};
    } finally {
      await reader.close();
    }
  } finally {
    await connection.close();
  }
}

Future<_Metric> _benchmarkConnect(
  String connectionString,
  _BenchConfig config,
) async {
  final sw = Stopwatch()..start();
  for (var i = 0; i < config.connectIterations; i++) {
    final connection = DpgsqlConnection(connectionString);
    await connection.open();
    await connection.close();
  }
  sw.stop();

  return _Metric.fromElapsed(sw.elapsed, config.connectIterations, 0);
}

Future<_Metric> _benchmarkSelectOne(
  DpgsqlConnection connection,
  _BenchConfig config,
) async {
  final command = DpgsqlCommand('SELECT 1', connection);
  var checksum = await _drainScalar(command, config.warmupIterations);

  final sw = Stopwatch()..start();
  checksum += await _drainScalar(command, config.iterations);
  sw.stop();

  return _Metric.fromElapsed(sw.elapsed, config.iterations, checksum);
}

Future<_Metric> _benchmarkParameter(
  DpgsqlConnection connection,
  _BenchConfig config,
) async {
  final parameters = DpgsqlParameterCollection()
    ..addWithValue('a', 40)
    ..addWithValue('b', 2);

  var checksum = await _drainScalarSql(
    connection,
    'SELECT @a::int + @b::int',
    parameters,
    config.warmupIterations,
  );

  final sw = Stopwatch()..start();
  checksum += await _drainScalarSql(
    connection,
    'SELECT @a::int + @b::int',
    parameters,
    config.iterations,
  );
  sw.stop();

  return _Metric.fromElapsed(sw.elapsed, config.iterations, checksum);
}

Future<_Metric> _benchmarkPrepared(
  DpgsqlConnection connection,
  _BenchConfig config,
) async {
  final command = DpgsqlCommand('SELECT @a::int + @b::int', connection);
  command.parameters.addWithValue('a', 40);
  command.parameters.addWithValue('b', 2);
  await command.prepare();

  var checksum = await _drainScalar(command, config.warmupIterations);

  final sw = Stopwatch()..start();
  checksum += await _drainScalar(command, config.iterations);
  sw.stop();

  return _Metric.fromElapsed(sw.elapsed, config.iterations, checksum);
}

Future<Map<String, dynamic>> _benchmarkResultSet(
  DpgsqlConnection connection,
  String tableName,
  int rowsPerQuery,
  _BenchConfig config,
) async {
  final command = DpgsqlCommand(
    'SELECT id, name, amount, created_at, payload '
    'FROM $tableName ORDER BY id LIMIT $rowsPerQuery',
    connection,
  );
  await command.prepare();

  var checksum = await _drainRows(command, config.resultSetWarmupIterations);

  final sw = Stopwatch()..start();
  checksum += await _drainRows(command, config.resultSetIterations);
  sw.stop();

  final elapsedSeconds =
      sw.elapsedMicroseconds / Duration.microsecondsPerSecond;
  final rowCount = rowsPerQuery * config.resultSetIterations;

  return {
    'rows_per_query': rowsPerQuery,
    'iterations': config.resultSetIterations,
    'warmup_iterations': config.resultSetWarmupIterations,
    'total_ms': sw.elapsedMicroseconds / 1000.0,
    'avg_ms': (sw.elapsedMicroseconds / 1000.0) / config.resultSetIterations,
    'queries_per_sec': config.resultSetIterations / elapsedSeconds,
    'rows_per_sec': rowCount / elapsedSeconds,
    'checksum': checksum,
  };
}

Future<Map<String, dynamic>> _benchmarkResultSetDrain(
  DpgsqlConnection connection,
  String tableName,
  int rowsPerQuery,
  _BenchConfig config,
) async {
  final command = DpgsqlCommand(
    'SELECT id, name, amount, created_at, payload '
    'FROM $tableName ORDER BY id LIMIT $rowsPerQuery',
    connection,
  );
  await command.prepare();

  var checksum =
      await _drainRowsOnly(command, config.resultSetWarmupIterations);

  final sw = Stopwatch()..start();
  checksum += await _drainRowsOnly(command, config.resultSetIterations);
  sw.stop();

  return _resultSetMetric(
    elapsed: sw.elapsed,
    rowsPerQuery: rowsPerQuery,
    iterations: config.resultSetIterations,
    warmupIterations: config.resultSetWarmupIterations,
    checksum: checksum,
  );
}

Future<Map<String, dynamic>> _benchmarkResultSetSimple(
  DpgsqlConnection connection,
  String tableName,
  int rowsPerQuery,
  _BenchConfig config,
) async {
  final command = DpgsqlCommand(
    'SELECT id, name, payload FROM $tableName ORDER BY id LIMIT $rowsPerQuery',
    connection,
  );
  await command.prepare();

  var checksum =
      await _drainRowsSimple(command, config.resultSetWarmupIterations);

  final sw = Stopwatch()..start();
  checksum += await _drainRowsSimple(command, config.resultSetIterations);
  sw.stop();

  return _resultSetMetric(
    elapsed: sw.elapsed,
    rowsPerQuery: rowsPerQuery,
    iterations: config.resultSetIterations,
    warmupIterations: config.resultSetWarmupIterations,
    checksum: checksum,
  );
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

Future<int> _drainScalar(DpgsqlCommand command, int iterations) async {
  var checksum = 0;
  for (var i = 0; i < iterations; i++) {
    final reader = await command.executeReader();
    try {
      if (await reader.read()) {
        checksum += reader.getValue(0) as int;
      }
    } finally {
      await reader.close();
    }
  }
  return checksum;
}

Future<int> _drainScalarSql(
  DpgsqlConnection connection,
  String sql,
  DpgsqlParameterCollection parameters,
  int iterations,
) async {
  var checksum = 0;
  for (var i = 0; i < iterations; i++) {
    final reader = await connection.executeReader(sql, parameters: parameters);
    try {
      if (await reader.read()) {
        checksum += reader.getValue(0) as int;
      }
    } finally {
      await reader.close();
    }
  }
  return checksum;
}

Future<int> _drainRows(DpgsqlCommand command, int iterations) async {
  var checksum = 0;
  for (var i = 0; i < iterations; i++) {
    final reader = await command.executeReader();
    try {
      while (await reader.read()) {
        checksum += (reader.getValue(0) as int) +
            reader.getValue(1).toString().length +
            reader.getValue(2).toString().length +
            reader.getValue(3).toString().length +
            reader.getValue(4).toString().length;
      }
    } finally {
      await reader.close();
    }
  }
  return checksum;
}

Future<int> _drainRowsOnly(DpgsqlCommand command, int iterations) async {
  var checksum = 0;
  for (var i = 0; i < iterations; i++) {
    final reader = await command.executeReader();
    try {
      while (await reader.read()) {
        checksum++;
      }
    } finally {
      await reader.close();
    }
  }
  return checksum;
}

Future<int> _drainRowsSimple(DpgsqlCommand command, int iterations) async {
  var checksum = 0;
  for (var i = 0; i < iterations; i++) {
    final reader = await command.executeReader();
    try {
      while (await reader.read()) {
        checksum += (reader.getValue(0) as int) +
            reader.getValue(1).toString().length +
            reader.getValue(2).toString().length;
      }
    } finally {
      await reader.close();
    }
  }
  return checksum;
}

Future<void> _ensureBenchmarkRows(
  DpgsqlConnection connection,
  String tableName,
  int targetRows,
) async {
  await DpgsqlCommand('''
CREATE TABLE IF NOT EXISTS $tableName (
  id INTEGER PRIMARY KEY,
  name VARCHAR(64) NOT NULL,
  amount NUMERIC(10, 2) NOT NULL,
  created_at TIMESTAMP NOT NULL,
  payload TEXT NOT NULL
)
''', connection).executeNonQuery();

  final countReader = await DpgsqlCommand(
    'SELECT COUNT(*) FROM $tableName',
    connection,
  ).executeReader();
  var existingRows = 0;
  try {
    if (await countReader.read()) {
      existingRows = countReader.getValue(0) as int;
    }
  } finally {
    await countReader.close();
  }

  if (existingRows >= targetRows) {
    return;
  }

  await DpgsqlCommand('TRUNCATE TABLE $tableName', connection)
      .executeNonQuery();

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

    await DpgsqlCommand(
      'INSERT INTO $tableName (id, name, amount, created_at, payload) '
      'VALUES ${values.join(',')}',
      connection,
    ).executeNonQuery();
  }
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
    final resultSetSizes = _env('BENCH_RESULTSET_SIZES', '10,1000,10000')
        .split(',')
        .map((s) => int.tryParse(s.trim()))
        .whereType<int>()
        .where((i) => i > 0)
        .toList(growable: false);

    return _BenchConfig(
      driverName: _env('BENCH_DRIVER_NAME', 'dpgsql'),
      host: _env('PGHOST', _env('POSTGRES_HOST', '127.0.0.1')),
      port: _envInt('PGPORT', _envInt('POSTGRES_PORT', 5432)),
      user: _env('PGUSER', _env('POSTGRES_USER', 'dart')),
      password: _env('PGPASSWORD', _env('POSTGRES_PASSWORD', 'dart')),
      database: _env('PGDATABASE', _env('POSTGRES_DATABASE', 'dart_test')),
      secure: _envBool('POSTGRES_SECURE', false),
      tableName: _env('BENCH_TABLE', 'bench_rows_dpgsql'),
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

  String get connectionString {
    final sslMode = secure ? 'Require' : 'Disable';
    return 'Host=$host;Port=$port;Username=$user;Password=$password;'
        'Database=$database;SSL Mode=$sslMode';
  }
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
  if (value == null || value.isEmpty) {
    return fallback;
  }
  return const {'1', 'true', 'yes', 'on'}.contains(value);
}
