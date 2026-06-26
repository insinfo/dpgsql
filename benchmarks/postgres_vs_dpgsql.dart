import 'dart:async';
import 'dart:io';

import 'package:dpgsql/dpgsql.dart' as dpgsql;
import 'package:postgres/postgres.dart' as pg;
import 'lorem_generator.dart';

Future<void> main(List<String> args) async {
  final connString = _resolveConnectionString(args);
  final iterations = _resolveIterations(args);
  final warmup = _resolveWarmup();
  final queryType = _resolveQueryType(args);
  final recordCount = _resolveRecordCount(args);

  stdout.writeln('Running benchmark with:');
  stdout.writeln('  connection string: $connString');
  stdout.writeln('  query type: $queryType');
  stdout.writeln('  warmup iterations: $warmup');
  stdout.writeln('  measured iterations: $iterations');

  // Setup do banco de dados
  if (queryType != 'simple') {
    stdout.writeln('\nSetting up benchmark database...');
    await _setupDatabase(connString, recordCount);
    stdout.writeln('Setup complete!\n');
  }

  final results = <String, Duration>{};

  try {
    results['dpgsql'] = await _runDpgsqlBenchmark(connString,
        warmup: warmup, iterations: iterations, queryType: queryType);
  } catch (e, st) {
    stderr.writeln('Failed to benchmark dpgsql: $e');
    stderr.writeln(st);
    return;
  }

  try {
    results['postgres'] = await _runPostgresBenchmark(connString,
        warmup: warmup, iterations: iterations, queryType: queryType);
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

String _resolveQueryType(List<String> args) {
  if (args.length >= 3 && args[2].trim().isNotEmpty) {
    return args[2].toLowerCase();
  }
  final fromEnv = Platform.environment['PG_BENCH_QUERY'];
  if (fromEnv != null && fromEnv.trim().isNotEmpty) {
    return fromEnv.trim().toLowerCase();
  }
  return 'simple'; // simple, select, join, aggregate
}

String _getQuery(String queryType) {
  switch (queryType) {
    case 'simple':
      return 'SELECT 1';
    case 'select':
      return 'SELECT * FROM benchmark_data LIMIT 100';
    case 'where':
      return "SELECT * FROM benchmark_data WHERE is_active = true LIMIT 100";
    case 'join':
      return '''
        SELECT bd1.*, bd2.email 
        FROM benchmark_data bd1 
        INNER JOIN benchmark_data bd2 ON bd1.id = bd2.id 
        WHERE bd1.is_active = true 
        LIMIT 50
      ''';
    case 'aggregate':
      return '''
        SELECT 
          is_active,
          COUNT(*) as total,
          AVG(price) as avg_price,
          SUM(quantity) as total_quantity
        FROM benchmark_data
        GROUP BY is_active
      ''';
    default:
      return 'SELECT 1';
  }
}

Future<Duration> _runDpgsqlBenchmark(String connString,
    {required int warmup,
    required int iterations,
    required String queryType}) async {
  final connection = dpgsql.DpgsqlConnection(connString);
  await connection.open();
  final query = _getQuery(queryType);
  final command = dpgsql.DpgsqlCommand(query, connection);

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
    {required int warmup,
    required int iterations,
    required String queryType}) async {
  final builder = dpgsql.DpgsqlConnectionStringBuilder(connString);
  final endpoint = pg.Endpoint(
    host: builder.host,
    port: builder.port,
    database: builder.database,
    username: builder.username,
    password: builder.password,
  );

  final connection = await pg.Connection.open(endpoint);
  final query = _getQuery(queryType);

  try {
    await _exercisePostgres(connection, query, warmup);
    final sw = Stopwatch()..start();
    await _exercisePostgres(connection, query, iterations);
    sw.stop();
    return sw.elapsed;
  } finally {
    await connection.close();
  }
}

Future<void> _exercisePostgres(
    pg.Connection connection, String query, int count) async {
  for (var i = 0; i < count; i++) {
    await connection.execute(query);
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

int _resolveRecordCount(List<String> args) {
  if (args.length >= 4) {
    final value = int.tryParse(args[3]);
    if (value != null && value > 0) {
      return value;
    }
  }
  final fromEnv = Platform.environment['PG_BENCH_RECORDS'];
  if (fromEnv != null) {
    final value = int.tryParse(fromEnv);
    if (value != null && value > 0) {
      return value;
    }
  }
  return 10000; // Default: 10k records
}

Future<void> _setupDatabase(String connString, int recordCount) async {
  final connection = dpgsql.DpgsqlConnection(connString);
  await connection.open();

  try {
    // Verificar se a tabela já existe e tem dados
    final checkCmd = dpgsql.DpgsqlCommand(
        "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'benchmark_data')",
        connection);
    final checkReader = await checkCmd.executeReader();
    bool tableExists = false;
    if (await checkReader.read()) {
      tableExists = checkReader.getValue(0) as bool;
    }
    await checkReader.close();

    int currentCount = 0;
    if (tableExists) {
      final countCmd = dpgsql.DpgsqlCommand(
          'SELECT COUNT(*) FROM benchmark_data', connection);
      final countReader = await countCmd.executeReader();
      if (await countReader.read()) {
        currentCount = countReader.getValue(0) as int;
      }
      await countReader.close();
    }

    if (currentCount >= recordCount) {
      stdout.writeln(
          '  Table already has $currentCount records. Skipping setup.');
      return;
    }

    // Criar a tabela
    stdout.write('  Creating table... ');
    await _createTable(connection);
    stdout.writeln('✓');

    // Popular com dados
    stdout.write('  Inserting $recordCount records... ');
    final sw = Stopwatch()..start();
    await _insertRecords(connection, recordCount);
    sw.stop();
    stdout.writeln('✓ (${sw.elapsed.inMilliseconds} ms)');

    // Verificar contagem final
    final finalCountCmd =
        dpgsql.DpgsqlCommand('SELECT COUNT(*) FROM benchmark_data', connection);
    final finalReader = await finalCountCmd.executeReader();
    int finalCount = 0;
    if (await finalReader.read()) {
      finalCount = finalReader.getValue(0) as int;
    }
    await finalReader.close();
    stdout.writeln('  Table now has $finalCount records.');
  } finally {
    await connection.close();
  }
}

Future<void> _createTable(dpgsql.DpgsqlConnection connection) async {
  final createTableSql = '''
    DROP TABLE IF EXISTS benchmark_data CASCADE;
    
    CREATE TABLE benchmark_data (
      id SERIAL PRIMARY KEY,
      name VARCHAR(255) NOT NULL,
      email VARCHAR(255) NOT NULL,
      title TEXT NOT NULL,
      description TEXT NOT NULL,
      content TEXT NOT NULL,
      price DECIMAL(10, 2) NOT NULL,
      quantity INTEGER NOT NULL,
      is_active BOOLEAN NOT NULL,
      created_at TIMESTAMP NOT NULL,
      updated_at TIMESTAMP NOT NULL
    );
    
    CREATE INDEX idx_benchmark_data_email ON benchmark_data(email);
    CREATE INDEX idx_benchmark_data_is_active ON benchmark_data(is_active);
    CREATE INDEX idx_benchmark_data_created_at ON benchmark_data(created_at);
  ''';

  final command = dpgsql.DpgsqlCommand(createTableSql, connection);
  await command.executeNonQuery();
}

Future<void> _insertRecords(
    dpgsql.DpgsqlConnection connection, int count) async {
  const batchSize = 1000;
  final batches = (count / batchSize).ceil();

  for (var b = 0; b < batches; b++) {
    final currentBatchSize =
        (b == batches - 1) ? count - (b * batchSize) : batchSize;

    final batch = dpgsql.DpgsqlBatch(connection);

    for (var i = 0; i < currentBatchSize; i++) {
      final insertCmd = batch.createBatchCommand('''
        INSERT INTO benchmark_data 
          (name, email, title, description, content, price, quantity, is_active, created_at, updated_at)
        VALUES 
          (@name, @email, @title, @description, @content, @price, @quantity, @is_active, @created_at, @updated_at)
      ''');

      insertCmd.parameters.addWithValue('name', LoremGenerator.name());
      insertCmd.parameters.addWithValue('email', LoremGenerator.email());
      insertCmd.parameters.addWithValue('title', LoremGenerator.title());
      insertCmd.parameters.addWithValue(
          'description', LoremGenerator.sentence(minWords: 10, maxWords: 20));
      insertCmd.parameters
          .addWithValue('content', LoremGenerator.paragraphs(3));
      insertCmd.parameters.addWithValue(
          'price', LoremGenerator.decimal(min: 10.0, max: 9999.99));
      insertCmd.parameters
          .addWithValue('quantity', LoremGenerator.integer(min: 0, max: 1000));
      insertCmd.parameters.addWithValue('is_active', LoremGenerator.boolean());
      insertCmd.parameters.addWithValue('created_at', LoremGenerator.date());
      insertCmd.parameters.addWithValue('updated_at', DateTime.now());
    }

    final reader = await batch.executeReader();
    await reader.close();

    if ((b + 1) % 10 == 0 || b == batches - 1) {
      stdout.write('.');
    }
  }
  stdout.writeln();
}
