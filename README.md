# dpgsql

[![Dart Testing](https://github.com/insinfo/dpgsql/actions/workflows/dart-testing.yml/badge.svg)](https://github.com/insinfo/dpgsql/actions/workflows/dart-testing.yml)

A high-performance PostgreSQL driver for Dart, implemented directly on top of the PostgreSQL wire protocol and inspired by the architecture and API shape of Npgsql.

`dpgsql` is intended for server-side Dart applications that need predictable behavior under long-running production workloads: connection pooling, prepared statements, binary I/O, pipeline mode, COPY support, notifications, SSL, and real PostgreSQL integration tests.

## Support My Work

[!["Buy Me A Coffee"](https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png)](https://www.buymeacoffee.com/isaqueneves)

I'm on Buy Me a Coffee. If this driver helps your project, you can buy me a coffee and share your thoughts: [buy me a coffee](https://www.buymeacoffee.com/isaqueneves).

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
- Type handlers for scalar types, arrays, ranges, JSON/JSONB, geometric types, timestamps, intervals, numeric, money, bytea, UUID, bit/varbit, and network address types.
- Large Object API.
- Logical replication protocol scaffolding.
- Benchmarks against Dart AOT and PHP PostgreSQL drivers.
- No external runtime dependencies; PostgreSQL timezone data needed for named
  IANA timezone decoding is vendored internally and opt-in.

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

## Network Address Types

For compatibility with text-oriented Dart PostgreSQL drivers and ORM/PDO-style
code, PostgreSQL `inet`, `cidr`, `macaddr`, and `macaddr8` values decode as
plain `String` by default.

Applications that prefer the more Npgsql-like typed values can opt in:

```dart
final connection = DpgsqlConnection(
  'Host=127.0.0.1;Database=postgres;Username=dart;Password=dart;'
  'Decode Network Types As String=false',
);
```

With that option disabled, the driver returns `DpgsqlInet`, `DpgsqlCidr`, and
`DpgsqlMacAddress`.

## Timestamp And Time Zone

By default `dpgsql` decodes PostgreSQL `date`, `timestamp`, and `timestamptz`
as UTC `DateTime` values. This matches the default behavior used by the Dart
`postgres` package and by the UTC defaults in `postgresql-fork`/`dargres`.

Applications that need local `DateTime` objects can opt in through the
connection string:

```dart
final connection = DpgsqlConnection(
  'Host=127.0.0.1;Database=postgres;Username=dart;Password=dart;'
  'TimeZone=America/Sao_Paulo;'
  'Force Decode Timestamp As UTC=false;'
  'Force Decode Timestamptz As UTC=false;'
  'Force Decode Date As UTC=false;'
  'Use Current Offset For Local Timestamp=false',
);
```

Setting `TimeZone=America/Sao_Paulo` alone only configures the PostgreSQL
session timezone. Named IANA conversion inside the driver is disabled by
default. To opt in to the vendored PostgreSQL/IANA timezone database for
non-UTC `timestamptz` decoding, also set:

```dart
'Use IANA Time Zone Database=true'
```

`latest_all` is used by default when the IANA database is enabled, so
historical values such as year 2000 timestamps follow historical DST rules.
Applications that only decode current/future timestamps can choose the compact
database to reduce runtime initialization cost:

```dart
'Use IANA Time Zone Database=true;IANA Time Zone Database Scope=latest_10y'
```

Npgsql's modern .NET behavior represents `timestamp without time zone` as an
unspecified `DateTimeKind` and `timestamptz` as UTC. Dart does not have an
equivalent to `DateTimeKind.Unspecified`, so `dpgsql` exposes the choice as
UTC (`isUtc == true`) or local (`isUtc == false`) decoding.

When pooling is enabled, `TimeZone` and `client_encoding` are restored after
connection reset so a reused physical connection keeps the configured session
semantics.

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

The benchmark suite compares `dpgsql` against pure Dart package drivers and PHP PostgreSQL drivers. Benchmark-only Dart dependencies live in `benchmarks/pubspec.yaml`, keeping the main package free of transitive benchmark dependencies. The PowerShell runner compiles the Dart benchmarks to native AOT before measurement.

Drivers currently included:

| Driver | Package/runtime | Notes |
|---|---|---|
| `dpgsql_aot` | local `dpgsql` | Native Dart AOT executable using this driver. |
| `postgres_fork` | `postgres_fork: ^2.8.5` | Legacy/forked pure Dart PostgreSQL driver. |
| `postgres_3` | `postgres: ^3.5.4` | Current Dart `postgres` package line. |
| `php_pgsql` | PHP `ext-pgsql` | Procedural native PHP PostgreSQL extension. |
| `php_pdo_pgsql` | PHP `PDO_PGSQL` | PDO PostgreSQL native extension. |
| `php_pgasync` | `voryx/PgAsync` | ReactPHP async client. |
| `php_amphp_postgres` | `amphp/postgres` | Amp async PostgreSQL client. |

Measured scenarios:

- connection open/close;
- `SELECT 1`;
- parameterized query;
- prepared or reusable parameterized query;
- result set drain without value access;
- result set with simple value access (`id`, `name`, `payload`);
- result set materialized as ORM-style `Map<String, dynamic>` rows;
- result set with fuller decoding (`id`, `name`, `numeric`, `timestamp`, `payload`).

```powershell
.\benchmarks\run_driver_comparison.ps1
```

Useful environment overrides:

```powershell
$env:PGHOST = "127.0.0.1"
$env:PGPORT = "5432"
$env:PGUSER = "dart"
$env:PGPASSWORD = "dart"
$env:PGDATABASE = "dart_test"
$env:BENCH_ITERATIONS = "2000"
$env:BENCH_RESULTSET_ITERATIONS = "20"
$env:BENCH_RESULTSET_SIZES = "10,1000,3000,10000"
.\benchmarks\run_driver_comparison.ps1
```

Reports are written under `benchmarks/reports/driver-comparison/`.
The generated `summary.md` contains one comparison table for scalar queries and six result-set/application tables (`drain`, `simple`, `maps`, `maps rawText`, `typed class + JSON`, and `full`).

Latest focused Dart AOT benchmark sample against PostgreSQL 16.7 on
`127.0.0.1` (`BENCH_ITERATIONS=200`,
`BENCH_RESULTSET_ITERATIONS=10`, `BENCH_RESULTSET_SIZES=1000`):

| Scenario | dpgsql AOT | postgres_fork 2.8.5 | postgres 3.5.x | Fastest Dart driver |
|---|---:|---:|---:|---|
| `SELECT 1` avg ms | 0.153 | 0.220 | 0.601 | `dpgsql_aot` |
| Parameterized avg ms | 0.207 | 0.262 | 0.719 | `dpgsql_aot` |
| Prepared avg ms | 0.169 | 0.265 | 0.219 | `dpgsql_aot` |
| Drain 1,000 rows avg ms | 1.812 | 4.553 | 7.237 | `dpgsql_aot` |
| Simple 1,000 rows avg ms | 1.198 | 2.113 | 3.847 | `dpgsql_aot` |
| Full formatted 1,000 rows avg ms | 2.511 | 4.334 | 6.859 | `dpgsql_aot` |

In this focused run `dpgsql_aot` is the fastest pure Dart driver across the
listed scalar, parameterized, prepared, drain, simple row, and full
`numeric` + `timestamp` formatted result-set paths. Longer p95/p99 and
allocation-focused runs remain tracked in `TODO.md`.

Focused ORM-map sample against PostgreSQL 16.7 on `127.0.0.1`
(`BENCH_ITERATIONS=200`, `BENCH_RESULTSET_ITERATIONS=5`,
`BENCH_RESULTSET_SIZES=10000`):

| Scenario | dpgsql AOT | postgres_fork 2.8.5 | postgres 3.5.x | php_pgsql | php_pdo_pgsql |
|---|---:|---:|---:|---:|---:|
| Typed maps 10,000 rows avg ms | 33.389 | 34.966 | 68.740 | 17.158 | 15.979 |
| PHP-style rawText maps 10,000 rows avg ms | 20.948 | - | - | 17.158 | 15.979 |
| Typed class + JSON 10,000 rows avg ms | 44.139 | - | - | 48.168 | 47.225 |

Application-level PHP comparison, forcing type conversion, typed object
hydration and JSON serialization:

| Scenario | dpgsql AOT | php_pgsql | php_pdo_pgsql | php_pgasync | php_amphp |
|---|---:|---:|---:|---:|---:|
| Typed class + JSON 10,000 rows avg ms | 44.139 | 48.168 | 47.225 | 104.555 | 58.729 |

`dpgsql_aot` currently leads the pure Dart drivers for ORM-style map
materialization. `PgResultMode.rawText` is an opt-in PHP-compatible mode that
requests text results and exposes every non-null field as `String`, reducing
10,000-row map materialization from 33.389 ms to 20.948 ms in this local run.
Native PHP `ext-pgsql`/`PDO_PGSQL` remains faster in the driver-only map
microbenchmark because those extensions are C/libpq wrappers returning mostly
strings. When PHP is forced to cast values, hydrate typed classes and serialize
JSON, `dpgsql_aot` leads the native PHP drivers in this sample.

For high-volume reads where not every column must be decoded immediately,
prefer `DpgsqlCommand.forEachPgRow()` or `DpgsqlCommand.executePgRows()`.
`forEachPgRow()` streams transient lazy `PgRow` views without building a result
list; `executePgRows()` materializes lazy row views when rows must be kept after
the command completes. Use `executeRows()` when you need a fully decoded
`List<List<Object?>>`. Use `executeMaps()` or `DpgsqlDataReader.readAllMaps()`
for ORM-style `Map<String, dynamic>` rows without adding an extra conversion
layer above the reader.

PostgreSQL `date`, `timestamp`, and `timestamptz` `infinity`/`-infinity`
values are exposed as `null` by default, matching compatibility expectations
from `postgresql-fork`/`dargres` style applications. Set
`Throw On DateTime Infinity=true` in the connection string to fail fast instead.
Named timezone support uses the generated Dart database in
`lib/src/utils/pg_timezone/timezone/pg_timezone_data_all.dart` and
`lib/src/utils/pg_timezone/timezone/pg_timezone_data_10y.dart`; runtime code
does not load `latest.tzf` or any external timezone file.

By default dpgsql uses `latest_all` when named IANA conversion is enabled. This
is the robust choice for historical PostgreSQL application data. The compact
`latest_10y` database is also shipped and can be selected with
`IANA Time Zone Database Scope=latest_10y`. To refresh the compact database from
the vendored `.tzf`, run:

```bash
dart run scripts/generate_pg_timezone_data.dart
```

To refresh the full historical database, run:

```bash
dart run scripts/generate_pg_timezone_data.dart --scope latest_all --output lib/src/utils/pg_timezone/timezone/pg_timezone_data_all.dart
```

To rebuild directly from IANA source files without `zic` or `package:timezone`,
use:

```bash
dart run scripts/generate_pg_timezone_data.dart --download-iana --scope latest_10y
```

## Continuous Integration

The GitHub Actions workflow `Dart Testing` runs on pushes and pull requests to `main`, across PostgreSQL 14, 15, 16, and 17. It installs Dart, analyzes the project, configures a real PostgreSQL service container, and runs the full test suite with real database coverage.

## Production Notes

- Prefer `DpgsqlDataSource` over manually opening connections for web servers.
- Always close readers before returning a pooled connection.
- Use explicit transactions for multi-statement consistency.
- Run integration tests against the same PostgreSQL major versions used in production.
- Keep benchmark reports when making performance-sensitive changes.
