/// Represents a PostgreSQL TIME value (time without date or timezone).
class NpgsqlTime implements Comparable<NpgsqlTime> {
  /// Hour (0-23)
  final int hour;

  /// Minute (0-59)
  final int minute;

  /// Second (0-59)
  final int second;

  /// Microseconds (0-999999)
  final int microsecond;

  const NpgsqlTime(this.hour, this.minute, this.second, [this.microsecond = 0]);

  /// Create from DateTime (date component is discarded).
  factory NpgsqlTime.fromDateTime(DateTime dt) {
    return NpgsqlTime(dt.hour, dt.minute, dt.second, dt.microsecond);
  }

  /// Create from microseconds since midnight.
  factory NpgsqlTime.fromMicrosecondsSinceMidnight(int microseconds) {
    final hours = microseconds ~/ 3600000000;
    final minutes = (microseconds % 3600000000) ~/ 60000000;
    final seconds = (microseconds % 60000000) ~/ 1000000;
    final micros = microseconds % 1000000;
    return NpgsqlTime(hours, minutes, seconds, micros);
  }

  /// Convert to microseconds since midnight.
  int toMicrosecondsSinceMidnight() {
    return hour * 3600000000 +
        minute * 60000000 +
        second * 1000000 +
        microsecond;
  }

  /// Convert to DateTime (date will be 1970-01-01).
  DateTime toDateTime() {
    return DateTime(1970, 1, 1, hour, minute, second, 0, microsecond);
  }

  /// Current time.
  factory NpgsqlTime.now() {
    final dt = DateTime.now();
    return NpgsqlTime(dt.hour, dt.minute, dt.second, dt.microsecond);
  }

  @override
  int compareTo(NpgsqlTime other) {
    return toMicrosecondsSinceMidnight()
        .compareTo(other.toMicrosecondsSinceMidnight());
  }

  @override
  bool operator ==(Object other) =>
      other is NpgsqlTime &&
      hour == other.hour &&
      minute == other.minute &&
      second == other.second &&
      microsecond == other.microsecond;

  @override
  int get hashCode => Object.hash(hour, minute, second, microsecond);

  @override
  String toString() {
    final h = hour.toString().padLeft(2, '0');
    final m = minute.toString().padLeft(2, '0');
    final s = second.toString().padLeft(2, '0');
    if (microsecond == 0) {
      return '$h:$m:$s';
    }
    final us = microsecond.toString().padLeft(6, '0');
    return '$h:$m:$s.$us';
  }

  /// Parse from PostgreSQL time string (HH:MM:SS or HH:MM:SS.ffffff).
  static NpgsqlTime parse(String s) {
    final parts = s.split(':');
    if (parts.length < 3) {
      throw FormatException('Invalid time format: $s');
    }

    final hour = int.parse(parts[0]);
    final minute = int.parse(parts[1]);

    final secondParts = parts[2].split('.');
    final second = int.parse(secondParts[0]);
    final microsecond = secondParts.length > 1
        ? int.parse(secondParts[1].padRight(6, '0').substring(0, 6))
        : 0;

    return NpgsqlTime(hour, minute, second, microsecond);
  }
}
