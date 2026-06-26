import 'dart:async';
import 'dart:io';

import 'package:dpgsql/dpgsql.dart' as dpgsql;
import 'package:postgres/postgres.dart' as pg;

Future<void> main(List<String> args) async {
  final connString = _resolveConnectionString(args);
  final iterations = _resolveIterations(args);
  final warmup = _resolveWarmup();

  stdout.writeln('Running benchmark with:');
  stdout.writeln('  connection string: $connString');
  stdout.writeln('  warmup iterations: $warmup');
  stdout.writeln('  measured iterations: $iterations');

  final results = <String, Duration>{};

  try {
    results['dpgsql'] = await _runDpgsqlBenchmark(connString,
        warmup: warmup, iterations: iterations);
  } catch (e, st) {
    stderr.writeln('Failed to benchmark dpgsql: $e');
    stderr.writeln(st);
    return;
  }

  try {
    results['postgres'] = await _runPostgresBenchmark(connString,
        warmup: warmup, iterations: iterations);
  } catch (e, st) {
    stderr.writeln('Failed to benchmark postgres package: $e');
    stderr.writeln(st);
    return;
  }

  stdout.writeln('\nResults (lower is better):');
  for (final entry in results.entries) {
    stdout.writeln(
        '  ${entry.key.padRight(10)} -> ${_formatDuration(entry.value)} (${_formatPerOp(entry.value, iterations)} per op)');
  }
}

String _resolveConnectionString(List<String> args) {
  if (args.isNotEmpty && args[0].trim().isNotEmpty) {
    return args[0];
  }
  final fromEnv = Platform.environment['PG_BENCH_CONN'];
  if (fromEnv != null && fromEnv.trim().isNotEmpty) {
    return fromEnv.trim();
  }
  return 'Host=localhost;Port=5432;Username=dart;Password=dart;Database=dart_test';
}

int _resolveIterations(List<String> args) {
  if (args.length >= 2) {
    final value = int.tryParse(args[1]);
    if (value != null && value > 0) {
      return value;
    }
  }
  final fromEnv = Platform.environment['PG_BENCH_ITERATIONS'];
  if (fromEnv != null) {
    final value = int.tryParse(fromEnv);
    if (value != null && value > 0) {
      return value;
    }
  }
  return 1000;
}

int _resolveWarmup() {
  final fromEnv = Platform.environment['PG_BENCH_WARMUP'];
  if (fromEnv != null) {
    final value = int.tryParse(fromEnv);
    if (value != null && value >= 0) {
      return value;
    }
  }
  return 100;
}

Future<Duration> _runDpgsqlBenchmark(String connString,
    {required int warmup, required int iterations}) async {
  final connection = dpgsql.DpgsqlConnection(connString);
  await connection.open();
  final command = dpgsql.DpgsqlCommand('SELECT 1', connection);

  await _exerciseDpgsql(command, warmup);
  final sw = Stopwatch()..start();
  await _exerciseDpgsql(command, iterations);
  sw.stop();

  await connection.close();
  return sw.elapsed;
}

Future<void> _exerciseDpgsql(dpgsql.DpgsqlCommand command, int count) async {
  for (var i = 0; i < count; i++) {
    final reader = await command.executeReader();
    try {
      while (await reader.read()) {
        // Drain rows to ensure full protocol roundtrip.
      }
    } finally {
      await reader.close();
    }
  }
}

Future<Duration> _runPostgresBenchmark(String connString,
    {required int warmup, required int iterations}) async {
  final builder = dpgsql.DpgsqlConnectionStringBuilder(connString);
  final endpoint = pg.Endpoint(
    host: builder.host,
    port: builder.port,
    database: builder.database,
    username: builder.username,
    password: builder.password,
  );

  final connection = await pg.Connection.open(endpoint);

  try {
    await _exercisePostgres(connection, warmup);
    final sw = Stopwatch()..start();
    await _exercisePostgres(connection, iterations);
    sw.stop();
    return sw.elapsed;
  } finally {
    await connection.close();
  }
}

Future<void> _exercisePostgres(pg.Connection connection, int count) async {
  for (var i = 0; i < count; i++) {
    await connection.execute('SELECT 1');
  }
}

String _formatDuration(Duration duration) {
  return duration.inMilliseconds >= 1000
      ? '${(duration.inMilliseconds / 1000).toStringAsFixed(3)} s'
      : '${(duration.inMicroseconds / 1000).toStringAsFixed(3)} ms';
}

String _formatPerOp(Duration total, int iterations) {
  if (iterations <= 0) return 'n/a';
  final micros = total.inMicroseconds / iterations;
  if (micros >= 1000) {
    return '${(micros / 1000).toStringAsFixed(3)} ms';
  }
  return '${micros.toStringAsFixed(3)} us';
}
