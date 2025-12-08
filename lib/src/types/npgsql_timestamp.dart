/// Represents a PostgreSQL TIMESTAMP or TIMESTAMPTZ value with proper timezone support.
class NpgsqlTimestamp implements Comparable<NpgsqlTimestamp> {
  /// The underlying DateTime value.
  final DateTime dateTime;

  /// Whether this timestamp includes timezone information.
  /// true for TIMESTAMPTZ, false for TIMESTAMP.
  final bool hasTimezone;

  const NpgsqlTimestamp(this.dateTime, {this.hasTimezone = false});

  /// Create a timestamp with timezone (TIMESTAMPTZ).
  factory NpgsqlTimestamp.withTimezone(DateTime dt) {
    return NpgsqlTimestamp(dt.toUtc(), hasTimezone: true);
  }

  /// Create a timestamp without timezone (TIMESTAMP).
  factory NpgsqlTimestamp.withoutTimezone(DateTime dt) {
    // Convert to local time if needed
    final local = dt.isUtc ? dt.toLocal() : dt;
    return NpgsqlTimestamp(local, hasTimezone: false);
  }

  /// Create from microseconds since PostgreSQL epoch (2000-01-01 00:00:00 UTC).
  factory NpgsqlTimestamp.fromMicrosecondsSinceEpoch(
    int microseconds, {
    bool hasTimezone = false,
  }) {
    final epoch = DateTime.utc(2000, 1, 1);
    final dt = epoch.add(Duration(microseconds: microseconds));
    return NpgsqlTimestamp(dt, hasTimezone: hasTimezone);
  }

  /// Convert to microseconds since PostgreSQL epoch (2000-01-01 00:00:00 UTC).
  int toMicrosecondsSinceEpoch() {
    final epoch = DateTime.utc(2000, 1, 1);
    final utc = dateTime.toUtc();
    return utc.difference(epoch).inMicroseconds;
  }

  /// Current timestamp with timezone.
  factory NpgsqlTimestamp.now() {
    return NpgsqlTimestamp.withTimezone(DateTime.now());
  }

  /// Convert to DateTime.
  DateTime toDateTime() => dateTime;

  /// Convert to UTC DateTime.
  DateTime toUtc() => dateTime.toUtc();

  /// Convert to local DateTime.
  DateTime toLocal() => dateTime.toLocal();

  @override
  int compareTo(NpgsqlTimestamp other) {
    return dateTime.compareTo(other.dateTime);
  }

  @override
  bool operator ==(Object other) =>
      other is NpgsqlTimestamp &&
      dateTime == other.dateTime &&
      hasTimezone == other.hasTimezone;

  @override
  int get hashCode => Object.hash(dateTime, hasTimezone);

  @override
  String toString() {
    final iso = dateTime.toIso8601String();
    return hasTimezone ? '$iso (with TZ)' : '$iso (without TZ)';
  }

  /// Parse from ISO 8601 string.
  static NpgsqlTimestamp parse(String s, {bool hasTimezone = false}) {
    final dt = DateTime.parse(s);
    return NpgsqlTimestamp(dt, hasTimezone: hasTimezone);
  }
}
