# Changelog

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
- Added opt-in vendored PostgreSQL/IANA timezone support for named `timestamptz` decoding without adding external runtime dependencies.
- Added nullable PostgreSQL date/time infinity handling by default, with `Throw On DateTime Infinity=true` for strict behavior.
- Added a pure Dart IANA timezone generator that parses `Rule`, `Zone`, and `Link` records without `zic.c` or `package:timezone`; local `.tzf` generation remains available for comparison, and the runtime-facing `latest.tzf` default filename was removed.
- Moved Dart package-driver benchmark dependencies to `benchmarks/pubspec.yaml` so the main package stays free of benchmark transitive dependencies.
- Added `result_sets_maps` benchmark coverage for `Map<String, dynamic>` row materialization.
- Added PHP associative-map benchmark coverage and 3000-row result-set scenarios.
- Added `DpgsqlCommand.forEachPgRowSync()` and cached command execution plans to reduce per-row and per-execution overhead in hot paths.
- Optimized repeated unprepared command planning by replacing per-execution string signatures with structural cache checks.
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
