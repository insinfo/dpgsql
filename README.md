# dpgsql

[![Dart Testing](https://github.com/insinfo/dpgsql/actions/workflows/dart-testing.yml/badge.svg)](https://github.com/insinfo/dpgsql/actions/workflows/dart-testing.yml)

A high-performance PostgreSQL driver for Dart, implemented directly on top of the PostgreSQL wire protocol and inspired by the architecture and API shape of Npgsql.

`dpgsql` is intended for server-side Dart applications that need predictable behavior under long-running production workloads: connection pooling, prepared statements, binary I/O, pipeline mode, COPY support, notifications, SSL, and real PostgreSQL integration tests.

## Status

The driver is usable for basic and intermediate PostgreSQL workloads and is actively being hardened for production. The public API now uses the `Dpgsql*` prefix.

Implemented areas include:

- Simple Query Protocol and Extended Query Protocol.
- Parameter binding with `$1`, `?`, and named `@parameter` placeholders.
- Prepared statements and auto-prepare cache.
- Connection pooling with max pool size, wait queue, checkout timeout, warmup, idle lifetime, and connection lifetime.
- Pipeline mode and batch execution.
- Binary COPY import/export.
- PostgreSQL notifications through `LISTEN`/`NOTIFY`.
- SSL modes and startup `client_encoding`.
- Type handlers for scalar types, arrays, ranges, JSON/JSONB, geometric types, timestamps, intervals, numeric, money, and bytea.
- Large Object API.
- Logical replication protocol scaffolding.
- Benchmarks against Dart AOT and PHP PostgreSQL drivers.

## Installation

Until the package is published, depend on the Git repository:

```yaml
dependencies:
  dpgsql:
    git:
      url: https://github.com/insinfo/dpgsql.git
```

Then run:

```bash
dart pub get
```

## Quick Start

```dart
import 'package:dpgsql/dpgsql.dart';

Future<void> main() async {
  final connection = DpgsqlConnection(
    'Host=127.0.0.1;Port=5432;Database=postgres;Username=dart;Password=dart',
  );

  await connection.open();
  try {
    final command = DpgsqlCommand('SELECT @value::int + 1', connection);
    command.parameters.addWithValue('value', 41);

    final reader = await command.executeReader();
    try {
      if (await reader.read()) {
        print(reader.getValue(0)); // 42
      }
    } finally {
      await reader.close();
    }
  } finally {
    await connection.close();
  }
}
```

## Connection Pooling

Use `DpgsqlDataSource` for application-level pooling:

```dart
final dataSource = DpgsqlDataSource(
  'Host=127.0.0.1;Database=postgres;Username=dart;Password=dart;'
  'Pooling=true;Minimum Pool Size=2;Maximum Pool Size=50;Timeout=15',
);

await dataSource.warmup();

final connection = await dataSource.openConnection();
try {
  final value = await connection.createCommand('SELECT 1').executeReader();
  await value.close();
} finally {
  await connection.close(); // returns the physical connector to the pool
}

print(dataSource.poolStats);
await dataSource.dispose();
```

## Prepared Statements

```dart
final command = DpgsqlCommand(
  'SELECT name FROM users WHERE id = @id',
  connection,
);
command.parameters.addWithValue('id', 1);

await command.prepare();

final reader = await command.executeReader();
await reader.close();
```

## Batch And Pipeline

```dart
final batch = connection.createBatch();
batch.createBatchCommand('SELECT 1');
batch.createBatchCommand('SELECT 2');

final reader = await connection.executeBatch(batch);
try {
  do {
    while (await reader.read()) {
      print(reader.getValue(0));
    }
  } while (await reader.nextResult());
} finally {
  await reader.close();
}
```

## COPY

```dart
final importer = await connection.beginBinaryImport(
  'COPY users (id, name) FROM STDIN (FORMAT BINARY)',
);

await importer.startRow();
await importer.write(1);
await importer.write('Alice');
await importer.complete();
```

## Notifications

```dart
await connection.createCommand('LISTEN app_events').executeNonQuery();

final subscription = connection.notifications.listen((notification) {
  print('${notification.channel}: ${notification.payload}');
});

await connection
    .createCommand("NOTIFY app_events, 'cache-invalidated'")
    .executeNonQuery();

await subscription.cancel();
```

## Encodings

`Client Encoding` controls the PostgreSQL startup parameter sent to the server. `Encoding` controls the local Dart codec used by the driver.

```dart
final connection = DpgsqlConnection(
  'Host=127.0.0.1;Database=postgres;Username=dart;Password=dart;'
  'Client Encoding=LATIN1;Encoding=LATIN1',
);
```

Supported local codecs include UTF-8, ASCII, LATIN1-10, ISO-8859-5/6/7/8, WIN1250-1254, WIN1256, KOI8-R, KOI8-U, BIG5, and GBK. Unsupported PostgreSQL encodings fail early instead of silently falling back to UTF-8.

## Running Tests

Unit tests can run without a local PostgreSQL server. Real integration tests use PostgreSQL when available and are mandatory in CI.

```bash
dart analyze
dart run test --concurrency 1 --chain-stack-traces --platform vm
```

To force real tests locally:

```bash
set DPGSQL_TEST_DB=Host=127.0.0.1;Port=5432;Database=dart_test;Username=dart;Password=dart;SSL Mode=Disable
dart run test --concurrency 1 --chain-stack-traces --platform vm
```

On Linux/macOS:

```bash
export DPGSQL_TEST_DB='Host=127.0.0.1;Port=5432;Database=dart_test;Username=dart;Password=dart;SSL Mode=Disable'
dart run test --concurrency 1 --chain-stack-traces --platform vm
```

## Benchmarks

The benchmark suite compares Dart AOT `dpgsql` with PHP PostgreSQL drivers such as `ext-pgsql`, `PDO_PGSQL`, `voryx/PgAsync`, and `amphp/postgres`.

```powershell
.\benchmarks\run_driver_comparison.ps1
```

Reports are written under `benchmarks/reports/driver-comparison/`.

## Continuous Integration

The GitHub Actions workflow `Dart Testing` runs on pushes and pull requests to `main`, across PostgreSQL 14, 15, 16, and 17. It installs Dart, analyzes the project, configures a real PostgreSQL service container, and runs the full test suite with real database coverage.

## Production Notes

- Prefer `DpgsqlDataSource` over manually opening connections for web servers.
- Always close readers before returning a pooled connection.
- Use explicit transactions for multi-statement consistency.
- Run integration tests against the same PostgreSQL major versions used in production.
- Keep benchmark reports when making performance-sensitive changes.
