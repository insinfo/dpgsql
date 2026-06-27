# Changelog

## 1.0.1

- Added `Use Extended Query For Unparameterized Commands`, allowing ORM/query-builder workloads to use extended protocol and binary result decoding for repeated single-statement queries without parameters.
- Added auto-prepare support for unparameterized `executeMaps()` when extended query mode is enabled, reusing cached `RowDescription` metadata.
- Optimized prepared `executeMaps()` with cached map metadata and a specialized raw message reader for the hot path.
- Added buffered backend-message draining via `PostgresMessageReader.tryReadMessage()`, reducing awaits when the socket already delivered multiple PostgreSQL messages.
- Reduced fixed query overhead in pooled ORM workloads with a no-reset pool fast path and synchronous safe return of pooled connections.
- Reduced per-execution overhead for unparameterized `DpgsqlCommand` calls by bypassing execution-plan allocation when no rewrite is needed.
- Removed temporary `ByteData.sublistView` allocations from primitive binary input/output paths.
- Improved Eloquent/SALI performance: larger AOT benchmark samples now show `dpgsql` matching or beating `postgresql-fork` on measured real SALI queries under pool concurrency, while still trailing on the `SELECT 1` microcase.
- Re-ran driver comparison benchmarks against `postgres_fork`, `postgres`, PHP `ext-pgsql`, PHP `PDO_PGSQL`, `voryx/PgAsync`, and `amphp/postgres`; `dpgsql_aot` remains ahead of Dart drivers on most result-set scenarios and wins application typed class + JSON serialization against measured PHP drivers.
- Added focused tests covering the extended unparameterized query option and auto-prepared unparameterized `executeMaps()`.

## 1.0.0

- Added PostgreSQL real integration coverage for pipeline, COPY, pooling, encodings, notifications, error recovery, and common type decoding.
- Added GitHub Actions workflow with PostgreSQL 14, 15, 16, and 17.
- Added README documentation with installation, pooling, prepared statements, batch/pipeline, COPY, notifications, encodings, tests, and benchmarks.
- Added benchmark comparison against `postgres_fork`, `postgres`, PHP `ext-pgsql`, PHP `PDO_PGSQL`, `voryx/PgAsync`, and `amphp/postgres`.
- Added application-level typed class + JSON benchmark to force PHP and Dart type conversion, object hydration, and serialization work.
- Added bundled codecs for PostgreSQL client encoding support.
- Implemented robust connection pooling with checkout wait queue, warmup, idle lifetime, connection lifetime, and pool metrics.
- Implemented lazy row decoding and fast paths for common scalar result types.
- Added typed data reader getters and optimized DataRow parsing/message reads for result-set hot paths.
- Added materialized `executeRows()` and lazy `executePgRows()` result-set APIs.
- Added `executeMaps()`, `DpgsqlDataReader.toMap()`, and `DpgsqlDataReader.readAllMaps()` for ORM-style map rows.
- Added `PgResultMode.rawText` for PHP-style `String`/`null` result access and raw text map benchmarks.
- Added `DpgsqlCommand.forEachPgRow()` for streaming transient lazy row views without result-list materialization.
- Added configurable `TimeZoneSettings` for UTC/default and local timestamp/date decoding, including pooled session restore for `TimeZone` and `client_encoding`.
- Added opt-in vendored PostgreSQL/IANA timezone support for named `timestamptz` decoding without adding external runtime dependencies, with `latest_all` as the robust default and `IANA Time Zone Database Scope=latest_10y` as the compact runtime option.
- Added nullable PostgreSQL date/time infinity handling by default, with `Throw On DateTime Infinity=true` for strict behavior.
- Added a pure Dart IANA timezone generator that parses `Rule`, `Zone`, and `Link` records without `zic.c`, `package:timezone`, or external reference directories; both `latest_all` and compact `latest_10y` generated databases are supported, and the runtime-facing `latest.tzf` default filename was removed.
- Moved Dart package-driver benchmark dependencies to `benchmarks/pubspec.yaml` so the main package stays free of benchmark transitive dependencies.
- Added `result_sets_maps` benchmark coverage for `Map<String, dynamic>` row materialization.
- Added PHP associative-map benchmark coverage and 3000-row result-set scenarios.
- Added `DpgsqlCommand.forEachPgRowSync()` and cached command execution plans to reduce per-row and per-execution overhead in hot paths.
- Optimized repeated unprepared command planning by replacing per-execution string signatures with structural cache checks.
- Added default PostgreSQL type inference for untyped string parameters (`Infer String Parameters As Unknown=true`), improving ORM compatibility for ISO timestamp strings and other context-typed columns while preserving explicit `DpgsqlDbType.text`/`varchar` behavior.
- Documented and validated Laravel/Eloquent-style `DateTime` bindings: ORMs may format `DateTime` as `yyyy-MM-dd HH:mm:ss`, and `dpgsql` keeps those untyped strings as PostgreSQL-inferred parameters by default so `timestamp without time zone` columns preserve wall-clock time.
- Added `Decode Uuid As String=true` default for ORM/PDO compatibility, with `Decode Uuid As String=false` preserving Npgsql-like `DpgsqlUuid` decoding.
- Added parsed `json`/`jsonb` decoding by default for ORM/PDO compatibility with nested model maps/lists, with `Decode Json As String=true` preserving raw JSON string decoding.
- Added non-string configuration entry points via `DpgsqlConnection.fromConnectionStringBuilder()` and `DpgsqlDataSource.fromConnectionStringBuilder()`, allowing integrations to pass configured settings directly instead of serializing a connection string.
- Applied configured session settings (`Search Path`, `Application Name`, `Statement Timeout`, `Lock Timeout`, and `Idle In Transaction Session Timeout`) directly from `DpgsqlConnectionStringBuilder` for both standalone connections and pooled data sources.
- Optimized binary date/timestamp/timestamptz conversion by avoiding `Duration` allocation in hot paths.
- Implemented text parsing for PostgreSQL `bytea` and `numeric`.
- Implemented text parsing for PostgreSQL range types.
- Fixed protocol recovery after `ErrorResponse` during reader initialization.
- Hardened auto-prepare fallback when no safe prepared statement slot is available.
- Implemented simple and extended PostgreSQL query protocol support.
- Added parameters, prepared statements, auto-prepare cache, batch execution, and pipeline mode.
- Added binary COPY import/export support.
- Added SSL modes, SCRAM-SHA-256 authentication, cancellation, and notifications.
- Added handlers for scalar types, arrays, JSON/JSONB, geometric types, ranges, timestamps, intervals, numeric, money, and bytea.
- Added large object and logical replication scaffolding.
