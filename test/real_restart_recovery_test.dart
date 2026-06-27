import 'dart:async';
import 'dart:io';

import 'package:dpgsql/dpgsql.dart';
import 'package:test/test.dart';

import 'test_config.dart';

void main() {
  test('pooled connection recovers after PostgreSQL service restart', () async {
    final restartCommand = Platform.environment['DPGSQL_RESTART_COMMAND'];
    if (restartCommand == null || restartCommand.trim().isEmpty) {
      print(
        'Skipping PostgreSQL restart test: set DPGSQL_RESTART_COMMAND to run it.',
      );
      return;
    }

    final dataSource = DpgsqlDataSource(
      realConnectionString(
        options: 'Pooling=true;Minimum Pool Size=1;Maximum Pool Size=4;'
            'Timeout=10;Connection Pruning Interval=1s',
      ),
    );

    await dataSource.warmup();

    try {
      await _expectScalar(dataSource, 1);

      final busyConnection = await dataSource.openConnection();
      final inFlight = busyConnection
          .executeScalar('SELECT pg_sleep(10), 1')
          .timeout(const Duration(seconds: 20))
          .then<_InFlightQueryResult>(
            (value) => _InFlightQueryValue(value),
            onError: (Object error, StackTrace stackTrace) =>
                _InFlightQueryError(error, stackTrace),
          );

      await Future<void>.delayed(const Duration(milliseconds: 800));
      await _runRestartCommand(restartCommand);

      final result = await inFlight;
      if (result is _InFlightQueryError) {
        busyConnection.markUnusable();
      }
      await busyConnection.close();

      expect(
        result,
        isA<_InFlightQueryError>(),
        reason: 'The in-flight query should fail when PostgreSQL restarts.',
      );
      expect(
        result is _InFlightQueryError,
        isTrue,
        reason: 'The in-flight query should fail when PostgreSQL restarts.',
      );

      await _expectScalarWithRetry(dataSource, 42);
    } finally {
      await dataSource.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}

Future<void> _runRestartCommand(String restartCommand) async {
  final result = await Process.run(
    'powershell',
    [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      restartCommand,
    ],
  ).timeout(const Duration(seconds: 45));

  if (result.exitCode != 0) {
    throw StateError(
      'Restart command failed with exit code ${result.exitCode}.\n'
      'stdout: ${result.stdout}\n'
      'stderr: ${result.stderr}',
    );
  }
}

Future<void> _expectScalar(DpgsqlDataSource dataSource, int expected) async {
  final connection = await dataSource.openConnection();
  try {
    final value = await connection
        .executeScalar('SELECT $expected')
        .timeout(const Duration(seconds: 5));
    expect(value, expected);
  } catch (_) {
    connection.markUnusable();
    rethrow;
  } finally {
    await connection.close();
  }
}

Future<void> _expectScalarWithRetry(
  DpgsqlDataSource dataSource,
  int expected,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 35));
  Object? lastError;

  while (DateTime.now().isBefore(deadline)) {
    try {
      await _expectScalar(dataSource, expected);
      return;
    } catch (e) {
      lastError = e;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  fail('PostgreSQL did not recover before timeout. Last error: $lastError');
}

sealed class _InFlightQueryResult {
  const _InFlightQueryResult();
}

final class _InFlightQueryValue extends _InFlightQueryResult {
  const _InFlightQueryValue(this.value);

  final Object? value;
}

final class _InFlightQueryError extends _InFlightQueryResult {
  const _InFlightQueryError(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;
}
