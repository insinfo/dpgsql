// Integration tests for pipeline features against a real PostgreSQL server
// Requires a local instance with credentials: user dart / password dart
// Database: postgres, Host: localhost, Port: 5432

import 'dart:io';

import 'package:dpgsql/dpgsql.dart';
import 'package:test/test.dart';

const _connString =
    'Host=localhost;Port=5432;Database=postgres;Username=dart;Password=dart;SSL Mode=Disable';

Future<NpgsqlConnection?> _openConnectionOrSkip() async {
  final conn = NpgsqlConnection(_connString);
  try {
    await conn.open();
    return conn;
  } on SocketException catch (e) {
    // Allow running tests without a local Postgres instance.
    // Users see a clear message but the suite does not fail.
    print('Skipping real pipeline test: $e');
    return null;
  }
}

void main() {
  test('executeCommandsPipelined mixes prepared and unprepared commands', () async {
    final conn = await _openConnectionOrSkip();
    if (conn == null) return;

    try {
      await conn
          .createCommand('DROP TABLE IF EXISTS pipeline_mix_validation')
          .executeNonQuery();

      await conn
          .createCommand(
              'CREATE TABLE pipeline_mix_validation ('
              'id serial PRIMARY KEY, '
              'name text NOT NULL, '
              'category text NOT NULL, '
              'score int NOT NULL)')
          .executeNonQuery();

      await conn
          .createCommand(
              "INSERT INTO pipeline_mix_validation (name, category, score) VALUES "
              "('Alpha', 'cat0', 10),"
              "('Beta', 'cat1', 20),"
              "('Gamma', 'cat1', 30),"
              "('Delta', 'cat2', 40)")
          .executeNonQuery();

      final prepared = conn.createCommand(
          'SELECT name FROM pipeline_mix_validation WHERE id = @id');
      prepared.parameters.addWithValue('id', 1);
      await prepared.prepare();
      prepared.parameters[0].value = 2; // Pick row with name Beta

      final counted = conn.createCommand(
          'SELECT COUNT(*) FROM pipeline_mix_validation WHERE category = @cat');
      counted.parameters.addWithValue('cat', 'cat1');

      final summed =
          conn.createCommand('SELECT SUM(score) FROM pipeline_mix_validation');

      final reader =
          await conn.executeCommandsPipelined([prepared, counted, summed]);

      expect(await reader.read(), isTrue);
      expect(reader[0], equals('Beta'));
      expect(await reader.read(), isFalse);

      expect(await reader.nextResult(), isTrue);
      expect(await reader.read(), isTrue);
      expect(reader[0], equals(2));
      expect(await reader.read(), isFalse);

      expect(await reader.nextResult(), isTrue);
      expect(await reader.read(), isTrue);
      expect(reader[0], equals(100));
      expect(await reader.read(), isFalse);
      expect(await reader.nextResult(), isFalse);

      await reader.close();
      expect(conn.inPipelineMode, isFalse);
    } finally {
      try {
        await conn
            .createCommand('DROP TABLE IF EXISTS pipeline_mix_validation')
            .executeNonQuery();
      } finally {
        await conn.close();
      }
    }
  });

  test('executeCommandsPipelined handles concurrent pipelines on multiple connections', () async {
    final setupConn = await _openConnectionOrSkip();
    if (setupConn == null) return;

    try {
      await setupConn
          .createCommand('DROP TABLE IF EXISTS pipeline_concurrency_validation')
          .executeNonQuery();

      await setupConn
          .createCommand(
              'CREATE TABLE pipeline_concurrency_validation ('
              'id serial PRIMARY KEY, '
              'category text NOT NULL, '
              'label text NOT NULL, '
              'score int NOT NULL)')
          .executeNonQuery();

      final values = <String>[];
      for (var i = 0; i < 12; i++) {
        final category = 'cat${i % 4}';
        final label = 'L${i + 1}';
        final score = (i + 1) * 10;
        values.add("('$category', '$label', $score)");
      }

      await setupConn
          .createCommand(
              'INSERT INTO pipeline_concurrency_validation (category, label, score) VALUES ${values.join(', ')}')
          .executeNonQuery();
    } finally {
      await setupConn.close();
    }

    Future<void> runPipeline(int index) async {
      final conn = await _openConnectionOrSkip();
      if (conn == null) return;

      try {
        final prepared = conn.createCommand(
            'SELECT COUNT(*) FROM pipeline_concurrency_validation WHERE category = @cat');
        prepared.parameters.addWithValue('cat', 'cat0');
        await prepared.prepare();
        prepared.parameters[0].value = 'cat$index';

        final arrayAgg = conn.createCommand(
            'SELECT array_agg(score ORDER BY score) FROM pipeline_concurrency_validation WHERE category = @cat');
        arrayAgg.parameters.addWithValue('cat', 'cat$index');

        final sumCmd = conn.createCommand(
            'SELECT SUM(score) FROM pipeline_concurrency_validation WHERE category = @cat');
        sumCmd.parameters.addWithValue('cat', 'cat$index');

        final reader =
            await conn.executeCommandsPipelined([prepared, arrayAgg, sumCmd]);

        expect(await reader.read(), isTrue);
        expect(reader[0], equals(3));
        expect(await reader.read(), isFalse);

        expect(await reader.nextResult(), isTrue);
        expect(await reader.read(), isTrue);
        final scores = reader[0];
        final expectedScores =
            List.generate(3, (k) => ((index + 1) + 4 * k) * 10);
        if (scores is List) {
          expect(scores, equals(expectedScores));
        } else if (scores is String) {
          expect(scores, startsWith('{'));
          expect(scores, endsWith('}'));
          final trimmed = scores.substring(1, scores.length - 1);
          final parsed = trimmed.isEmpty
              ? <int>[]
              : trimmed
                  .split(',')
                  .map((segment) => int.parse(segment.trim()))
                  .toList();
          expect(parsed, equals(expectedScores));
        } else {
          fail('Unexpected array_agg return type: ${scores.runtimeType}');
        }
        expect(await reader.read(), isFalse);

        expect(await reader.nextResult(), isTrue);
        expect(await reader.read(), isTrue);
        final expectedSum =
            expectedScores.fold<int>(0, (acc, value) => acc + value);
        expect(reader[0], equals(expectedSum));
        expect(await reader.read(), isFalse);
        expect(await reader.nextResult(), isFalse);

        await reader.close();
        expect(conn.inPipelineMode, isFalse);
      } finally {
        await conn.close();
      }
    }

    await Future.wait(List.generate(4, runPipeline));

    final cleanupConn = await _openConnectionOrSkip();
    if (cleanupConn == null) return;
    try {
      await cleanupConn
          .createCommand('DROP TABLE IF EXISTS pipeline_concurrency_validation')
          .executeNonQuery();
    } finally {
      await cleanupConn.close();
    }
  });
}
