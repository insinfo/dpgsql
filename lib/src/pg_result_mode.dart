/// Controls how PostgreSQL result values are exposed by readers and
/// materialized row APIs.
enum PgResultMode {
  /// Decode values to Dart types using the registered type handlers.
  typed,

  /// Request text results from PostgreSQL and expose every non-null field as
  /// [String], similar to PHP ext-pgsql/libpq default fetching.
  rawText,
}
