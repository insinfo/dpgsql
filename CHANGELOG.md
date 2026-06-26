# Changelog

## 1.0.0

- Added PostgreSQL real integration coverage for pipeline, COPY, pooling, encodings, notifications, error recovery, and common type decoding.
- Added GitHub Actions workflow with PostgreSQL 14, 15, 16, and 17.
- Added README documentation with installation, pooling, prepared statements, batch/pipeline, COPY, notifications, encodings, tests, and benchmarks.
- Added bundled codecs for PostgreSQL client encoding support.
- Implemented robust connection pooling with checkout wait queue, warmup, idle lifetime, connection lifetime, and pool metrics.
- Implemented lazy row decoding and fast paths for common scalar result types.
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
