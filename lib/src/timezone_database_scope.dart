/// Selects which vendored PostgreSQL/IANA timezone database is used when
/// `Use IANA Time Zone Database=true`.
enum PgTimeZoneDatabaseScope {
  /// Full historical timezone transitions. This is the robust default.
  latestAll,

  /// Compact database around the current period. Useful when applications only
  /// decode current/future timestamps and want lower runtime initialization cost.
  latest10y,
}

PgTimeZoneDatabaseScope parsePgTimeZoneDatabaseScope(String value) {
  switch (value.trim().toLowerCase().replaceAll('-', '_')) {
    case 'latest_all':
    case 'all':
    case 'full':
      return PgTimeZoneDatabaseScope.latestAll;
    case 'latest_10y':
    case '10y':
    case 'compact':
      return PgTimeZoneDatabaseScope.latest10y;
    default:
      throw ArgumentError.value(
        value,
        'value',
        'Use latest_all or latest_10y.',
      );
  }
}

String pgTimeZoneDatabaseScopeName(PgTimeZoneDatabaseScope scope) {
  return switch (scope) {
    PgTimeZoneDatabaseScope.latestAll => 'latest_all',
    PgTimeZoneDatabaseScope.latest10y => 'latest_10y',
  };
}
