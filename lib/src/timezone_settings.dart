import 'timezone_database_scope.dart';

/// Configures how PostgreSQL date/time values are decoded to Dart [DateTime].
///
/// The defaults match `postgres`, `postgresql-fork`, and `dargres`: date,
/// timestamp, and timestamptz are decoded as UTC values. Set the force flags to
/// false to use local DateTime semantics closer to PostgreSQL timestamp without
/// time zone behavior.
class TimeZoneSettings {
  const TimeZoneSettings(
    this.value, {
    this.forceDecodeTimestamptzAsUTC = true,
    this.forceDecodeTimestampAsUTC = true,
    this.forceDecodeDateAsUTC = true,
    this.useCurrentOffsetForLocalTimestamp = true,
    this.useIanaTimeZoneDatabase = false,
    this.ianaTimeZoneDatabaseScope = PgTimeZoneDatabaseScope.latestAll,
    this.throwOnDateTimeInfinity = false,
  });

  const TimeZoneSettings.utc()
      : value = 'UTC',
        forceDecodeTimestamptzAsUTC = true,
        forceDecodeTimestampAsUTC = true,
        forceDecodeDateAsUTC = true,
        useCurrentOffsetForLocalTimestamp = true,
        useIanaTimeZoneDatabase = false,
        ianaTimeZoneDatabaseScope = PgTimeZoneDatabaseScope.latestAll,
        throwOnDateTimeInfinity = false;

  /// PostgreSQL session time zone name. Sent as the `TimeZone` startup
  /// parameter when present in the connection string.
  final String value;

  /// If true, decode `timestamptz` as UTC. If false, decode as local time.
  final bool forceDecodeTimestamptzAsUTC;

  /// If true, decode `timestamp without time zone` as UTC. If false, decode as
  /// local time.
  final bool forceDecodeTimestampAsUTC;

  /// If true, decode `date` as UTC midnight. If false, decode as local
  /// midnight.
  final bool forceDecodeDateAsUTC;

  /// When local decoding is enabled, ignore historical system timezone
  /// transitions by using the current local offset as the PostgreSQL epoch
  /// offset. This mirrors the optional correction used by `postgresql-fork`.
  final bool useCurrentOffsetForLocalTimestamp;

  /// If true, decode non-UTC `timestamptz` values through the vendored
  /// PostgreSQL/IANA timezone database. Disabled by default so applications
  /// that only set the PostgreSQL session `TimeZone` do not pay this behavior.
  final bool useIanaTimeZoneDatabase;

  /// Selects the vendored IANA database scope used when
  /// [useIanaTimeZoneDatabase] is true. Full history is the default so dates
  /// such as year 2000 decode with historical DST rules.
  final PgTimeZoneDatabaseScope ianaTimeZoneDatabaseScope;

  /// If true, throw when PostgreSQL returns `date`, `timestamp`, or
  /// `timestamptz` infinity sentinels. Defaults to false, matching
  /// `postgresql-fork`/`dargres` compatibility by exposing infinity as null
  /// through row materialization APIs.
  final bool throwOnDateTimeInfinity;

  TimeZoneSettings copyWith({
    String? value,
    bool? forceDecodeTimestamptzAsUTC,
    bool? forceDecodeTimestampAsUTC,
    bool? forceDecodeDateAsUTC,
    bool? useCurrentOffsetForLocalTimestamp,
    bool? useIanaTimeZoneDatabase,
    PgTimeZoneDatabaseScope? ianaTimeZoneDatabaseScope,
    bool? throwOnDateTimeInfinity,
  }) {
    return TimeZoneSettings(
      value ?? this.value,
      forceDecodeTimestamptzAsUTC:
          forceDecodeTimestamptzAsUTC ?? this.forceDecodeTimestamptzAsUTC,
      forceDecodeTimestampAsUTC:
          forceDecodeTimestampAsUTC ?? this.forceDecodeTimestampAsUTC,
      forceDecodeDateAsUTC: forceDecodeDateAsUTC ?? this.forceDecodeDateAsUTC,
      useCurrentOffsetForLocalTimestamp: useCurrentOffsetForLocalTimestamp ??
          this.useCurrentOffsetForLocalTimestamp,
      useIanaTimeZoneDatabase:
          useIanaTimeZoneDatabase ?? this.useIanaTimeZoneDatabase,
      ianaTimeZoneDatabaseScope:
          ianaTimeZoneDatabaseScope ?? this.ianaTimeZoneDatabaseScope,
      throwOnDateTimeInfinity:
          throwOnDateTimeInfinity ?? this.throwOnDateTimeInfinity,
    );
  }
}
