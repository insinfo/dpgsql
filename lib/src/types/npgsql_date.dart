/// Represents a PostgreSQL DATE value (date without time).
/// More precise than DateTime for date-only values.
class NpgsqlDate implements Comparable<NpgsqlDate> {
  /// Year (e.g., 2024)
  final int year;

  /// Month (1-12)
  final int month;

  /// Day (1-31)
  final int day;

  const NpgsqlDate(this.year, this.month, this.day);

  /// Create from DateTime (time component is discarded).
  factory NpgsqlDate.fromDateTime(DateTime dt) {
    return NpgsqlDate(dt.year, dt.month, dt.day);
  }

  /// Create from PostgreSQL days since epoch (2000-01-01).
  factory NpgsqlDate.fromDaysSinceEpoch(int days) {
    final epoch = DateTime.utc(2000, 1, 1);
    final dt = epoch.add(Duration(days: days));
    return NpgsqlDate(dt.year, dt.month, dt.day);
  }

  /// Convert to days since PostgreSQL epoch (2000-01-01).
  int toDaysSinceEpoch() {
    final epoch = DateTime.utc(2000, 1, 1);
    final thisDate = DateTime.utc(year, month, day);
    return thisDate.difference(epoch).inDays;
  }

  /// Convert to DateTime (time will be midnight UTC).
  DateTime toDateTime() {
    return DateTime.utc(year, month, day);
  }

  /// Today's date.
  factory NpgsqlDate.today() {
    final now = DateTime.now();
    return NpgsqlDate(now.year, now.month, now.day);
  }

  @override
  int compareTo(NpgsqlDate other) {
    if (year != other.year) return year.compareTo(other.year);
    if (month != other.month) return month.compareTo(other.month);
    return day.compareTo(other.day);
  }

  @override
  bool operator ==(Object other) =>
      other is NpgsqlDate &&
      year == other.year &&
      month == other.month &&
      day == other.day;

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() {
    final y = year.toString().padLeft(4, '0');
    final m = month.toString().padLeft(2, '0');
    final d = day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  /// Parse from ISO 8601 date string (YYYY-MM-DD).
  static NpgsqlDate parse(String s) {
    final parts = s.split('-');
    if (parts.length != 3) {
      throw FormatException('Invalid date format: $s');
    }
    return NpgsqlDate(
      int.parse(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]),
    );
  }
}
