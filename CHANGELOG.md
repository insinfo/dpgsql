# Changelog

## 1.1.1

- fix: the session settings (`Search Path`, `Application Name`, `Statement
  Timeout`, `Lock Timeout`, `Idle In Transaction Session Timeout`) ran with a
  fixed 100 ms timeout per `SET`. On a server whose replies take longer (in
  another region, or busy starting many backends) `DpgsqlConnection.open()`
  failed with `TimeoutException after 0:00:00.100000`, and
  `DpgsqlDataSource` ignored the timeout and handed out the connection with
  the `SET` still running: the settings were missing and the caller's query
  read the pending reply ("Buffer interno menor que o esperado"). They now
  use the connection `Timeout` (15 s by default); the data source skips
  only a setting the server rejects and discards the connection on any
  other error
- fix: the pool's health check and step-by-step reset used the same 100 ms
  timeout, and the health check counted a timeout as healthy, returning a
  connection with the `SELECT 1` still running to the pool; they use the
  5 s reset timeout and a timeout discards the connection

## 1.1.0

- `DpgsqlCommand.simpleQuery`: the command goes through the simple query
  protocol (libpq's `PQexec`) even with `Use Extended Query For
  Unparameterized Commands=true`, so a script with several statements
  (`create ...; insert ...; begin; ...; commit;`) runs in one round trip;
  with the extended protocol PostgreSQL refuses it (42601). It takes no
  parameters and cannot be prepared or pipelined (`StateError`); only
  `executeReader` and `executeNonQuery` use it (the other `execute*`
  methods throw instead of ignoring it). `DpgsqlConnection.executeReader`
  takes `simpleQuery:` too.

## 1.0.3

- Performance, `DpgsqlDataSource`: the pool settings are read once, when the
  data source is created. Every checkout and return read them again from the
  connection-string builder, which looks a keyword up through all its
  aliases (and through every parameter when it is not set): about 34 µs of
  CPU per checkout and return, now 1 µs; a pooled `select 1` is as fast as on
  a single connection.
- Performance, `DpgsqlDataSource` without `No Reset On Close`: a reused
  connection is reset in one round trip (ROLLBACK, RESET ALL, CLOSE ALL,
  UNLISTEN * and the session settings in one simple-protocol query). It took
  up to seven (a health check, each statement, each session SET, another
  health check): about 322 µs per checkout on a local server, now 166 µs.
  The reset is also the health check; a connection that does not answer it
  within 5 s is discarded instead of being handed out (its late answer would
  have been read by the next command).

- Performance: a parameterized query auto-prepared in the same round trip as
  its first execution keeps its result columns, so the next executions get
  binary results for the columns with a binary decoder; they all asked for
  text. With the text `timestamp` decoding below, a 100-row result with a
  timestamp column took 3.4 ms instead of 0.34 ms.
- Performance: `date`, `timestamp` and `timestamptz` text values (DateStyle
  ISO) are read digit by digit; `DateTime.parse` took about 30 µs per value.
  BC dates, infinity and years after 9999 still go through `DateTime.parse`.

- One-dimensional arrays are lists of their element type (`List<int?>`,
  `List<String?>`, `List<DateTime?>`...), so `as List<int?>` works. They were
  a `CastList<dynamic, dynamic>`.

- `Decode Extended Types As Text=true`: the types without a natural Dart
  type come back as the text the server prints for them, in the text and the
  binary formats: `interval` (`'1 day 02:03:04'`), `time`/`timetz`,
  `inet`/`cidr`/`macaddr`, geometric types (`'(1,2)'`, `'<(1,2),3>'`),
  `bit`/`varbit`, `tsvector`, ranges (`'[1,5)'`, `'[2024-01-01,2024-02-01)'`)
  and their arrays (lists of texts); `money` as the decimal amount
  (`'12.34'`, from the binary value or the lc_monetary text). Off by default
  (DpgsqlInterval, DpgsqlMoney, DpgsqlPoint, DpgsqlRange...).

- Result columns without a binary decoder (enums, `tsvector`, `regclass`
  and the other reg* types, arrays of user-defined types, ...) came back as
  their binary bytes, which could not be told apart from `bytea`: an enum
  `'ok'` was `[111, 107]`. Results are now requested per column: binary for
  the columns with a binary decoder, text for the others, which come back as
  the server's text (`'ok'`, `"'a' 'b'"`, `'pg_class'`, `'{ok,sad}'`). A
  statement parsed in the same round trip as its execution (its columns are
  not known yet) gets every column in text, as the simple protocol does; a
  prepared or auto-prepared one gets the per-column formats. The PgRow APIs
  (`executePgRows`, `forEachPgRow`) still read every column in binary.
  `writeBind` no longer rejects per-column result formats (it compared their
  number with the number of parameters).
- `float4` read in text gives the same double as in binary
  (`1.100000023841858` for `1.1`; `double.parse` gave `1.1`).

- Exact `numeric`: `Decode Numeric As String=true` returns the server's text
  (`'150.50'`, `'12345678901234567890.123456789'`, `'NaN'`; arrays as lists of
  strings) and `Use Custom Decimal=true` a `DpgsqlDecimal`, in the text and
  binary formats and on every read path. By default numeric is still the
  nearest `double`, which loses digits beyond about 15 significant ones and
  the scale. `DpgsqlDecimal` and the `useCustomDecimal` flag existed but no
  connection option reached them. A `DpgsqlDbType.numeric` parameter now
  accepts a `String`, a `num` or a `DpgsqlDecimal` (each handler accepted only
  its own type), and a `DpgsqlDecimal` parameter is sent as numeric.
  `DpgsqlTypesConfig` is still not read by connections.

- Fixed results shifting after an error raised while a response was being
  read (a cancelled statement, or a failure after `RowDescription`): the
  `ReadyForQuery` that ends the response was left unread, so the next command
  returned `[]` and every later command the previous command's result. All
  reader and fast paths (`executeMaps`, `executeRows`, `executeScalar`,
  prepared statements, `prepare`, COPY) now consume the response before
  throwing; errors also carry `detail` and `hint` on every path.
- `Map` parameters (and lists of maps) are sent as JSON. They were sent with
  `toString()` (`{a: 1}`), which `json`/`jsonb` reject.
- With `Infer String Parameters As Unknown` (the default), lists of strings
  are sent as untyped array literals, like single strings, so the server
  infers the element type: `uuid_col = any(?)` no longer fails with
  `operator does not exist: uuid = text`.
- A second command on a connection that is still running one (sending,
  reading, an open reader or a COPY) used to interleave with the first: both
  read each other's responses, returning wrong rows or crashing the read loop
  with "Buffer interno menor que o esperado". Concurrent callers now wait for
  their turn, in call order (`DpgsqlConnection.queueConcurrentCalls`, default
  `true`); an open reader or COPY keeps the turn until it is closed. With
  `queueConcurrentCalls = false` the second command fails immediately with a
  clear `StateError`. Pipeline mode is unchanged.
- `DpgsqlConnection.runInTransaction(action)`: commits, or rolls back when
  `action` throws. The transaction holds the connection: commands and
  transactions from other callers wait until it ends, while commands from
  `action` (on the transaction or the connection, concurrent ones included,
  recognized through a `Zone` value) run inside it. A transaction opened with
  `beginTransaction()` has no such protection. `DpgsqlTransaction.isCompleted`
  tells whether it was committed or rolled back.
- `executeMaps` and `executeRows` of a command without rows (DDL, `SET`, `DO`,
  an INSERT without RETURNING, ...) left the response's `ReadyForQuery`
  unread: the next command returned that empty result and every later one
  the previous command's result.
- Notifications are not drained from the socket while a caller waits for its
  turn: the drain could race the next command's read.
- `LISTEN` notifications are delivered while the connection is idle. They
  were read only when the next command ran on the listening connection.
- Protocol strings (column names, error and notice fields, notification
  payloads, parameter values) are decoded as UTF-8. They were decoded as
  Latin-1, so `"situação"` or a Portuguese error message came out garbled.
- `@name` and `?` placeholders are no longer read inside comments (`--`,
  nested `/* */`), dollar-quoted strings (`$$...$$`, `$tag$...$tag$`) or the
  backslash escapes of `E'...'` strings. An apostrophe in a comment opened a
  string and shifted every placeholder after it (syntax error).
- `DpgsqlConnection.onConnectionLost` emits when the server closes an open
  connection; `close()` after that no longer writes `Terminate` to the closed
  socket (it raised an uncaught error).
- Bytes already read from the socket are no longer overwritten: rows,
  queued messages and values are views of the read buffer, which was
  compacted in place (or written again from its start once fully read) when
  more data arrived. A reader's current row changed when the caller awaited
  between `read()` and `getValue()` (wrong values, "Invalid radix-10
  number"), and `bytea` values already returned changed with later commands.
- A value that fails to decode, or a `forEachPgRow` callback that throws, no
  longer shifts the later results: the rest of the response is read first.
- Prepared `executeMaps` (the fast path) reads up to `ReadyForQuery` before
  throwing a server error: it threw at once, and the next command returned
  the previous one's leftovers.
- A batch (`createBatch`, `executeCommandsPipelined`) whose first command
  fails reads its `ReadyForQuery`: the next command returned `null` and
  every later one the previous command's result.
- A parameter that fails to encode (a `Map` holding a non-JSON value, an
  out-of-range `int`) no longer hangs the connection: `Parse` was buffered
  before the values were encoded and sent ahead of the next command, which
  the server then skipped.
- `int` parameters beyond the int4 range are sent as int8; they were
  truncated to 32 bits (2^31 arrived as -2^31). `DpgsqlDbType.bigint` and
  `smallint` encode 8 and 2 bytes (they sent int4), and out-of-range values
  for int2/int4 throw an `ArgumentError` instead of being truncated. Lists
  with values beyond int4 are sent as `int8[]`.
- Binary `numeric` `NaN`, `Infinity` and `-Infinity` decode as such (they
  were 0.0), and binary values decode to the same double as their text (the
  digits were accumulated with a rounding at each step). There is still no
  exact `numeric` type: use `PgResultMode.rawText` or cast to text.
- `time` and `timetz` in the binary format decode as PostgreSQL prints them
  (`12:34:56.789`, `12:34:56+05:30`), like the text format; they came back
  as raw bytes. `oid` decodes as an `int` and `xml` as a `String`.
- Arrays of `int2`, `int8`, `numeric`, `oid`, `varchar`, `bpchar`, `"char"`,
  `bytea`, `date`, `time`, `timetz`, `timestamp`, `timestamptz`, `interval`,
  `uuid`, `json`, `jsonb`, `inet` and `cidr` are decoded; they came back as
  raw bytes (binary) or as the literal text (`{1,2}`). A `List<Uint8List>`
  parameter is sent as `bytea[]` (it was read as nested int arrays).
- Text-format dates and timestamps before Christ (`0044-03-15 BC`) decode;
  they threw a `FormatException`.
- `money` in the text format honors the server locale's separators:
  `R$ 1.234,56` came back as 1.23 and `R$ 12,34` as 1234.00.
- An interval whose time part is negative with zero hours
  (`-1 days -00:00:01`) keeps its sign in the text format.
- A JSON `null` (`'null'::jsonb`) decodes as `null` in `executeMaps`/
  `executeRows`; it came back as raw bytes.
- `executePgRows`, `forEachPgRow` and `forEachPgRowSync` without a prepared
  statement return real binary rows with the column names and types: they
  were rebuilt from text values named `column_0, column_1, ...`, so `getInt`,
  `getDouble`, `getDateTime` threw and `getByName` failed. They now use the
  extended protocol (one statement per command).
- `executeMaps`, `executeRows` and `executeScalar` of several statements
  return the rows of a statement that follows one without rows
  (`create ...; insert ...; select ...`); they were dropped.
- `executeScalar` reads the whole response, so an error raised after the
  first row or by a later statement is thrown (the first value of a failed
  statement was returned), and statements without rows before the query are
  skipped, as in `executeMaps`.
- `executeNonQuery` reads every statement and returns the sum of their
  counts: only the first was read, so a failing later statement went
  unnoticed.
- `$1, $2, ...` placeholders bind the parameters in collection order; the
  parameters were dropped (08P01 / 42P02). Parameter names may carry the
  Npgsql `@` or `:` prefix (`addWithValue('@id', 1)`).
- An auto-prepared statement the server rejects after a schema change
  ("cached plan must not change result type", 0A000) or no longer has
  (26000, `DEALLOCATE ALL`) fails once and is prepared again; it failed on
  every later execution. An unparameterized command without rows
  (`Use Extended Query For Unparameterized Commands`) no longer fails its
  third run with "prepared statement already exists" (42P05).
- A failed COPY (a rejected row, an error in the middle of `COPY TO`) ends
  the operation and leaves the connection usable; it kept the connection's
  turn and every later command waited forever. A `COPY TO` closed before its
  end, a cancelled `COPY FROM` (`cancel()`, `DpgsqlBinaryImporter.close()`)
  and a failed binary export read the rest of their response instead of
  leaving it to the next command.
- `cancel()` closes the socket of its cancel request; it stayed open and
  kept the process from exiting.
- Notices, notifications and `onConnectionLost` are delivered on
  `DpgsqlDataSource` connections; they were wired only by `open()`, so
  `LISTEN` did not work on pooled connections.
- A command on a connection the server closed fails at once with a
  `StateError`; it wrote to the closed socket (a `SocketException`, or an
  uncaught assertion of `dart:io` in debug mode).

## 1.0.2

- Fixed decoding of the system-catalog string types `name` (OID 19) and the
  internal single-byte `"char"` (OID 18): they were returned as raw bytes
  (`Uint8List`) instead of `String`. For example `SELECT datname FROM pg_database`
  now returns `String` values. Also registered a text `ArrayHandler` for
  `name[]` (OID 1003). Application string types (`text`, `varchar`, `char(n)`)
  were already handled correctly.

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
