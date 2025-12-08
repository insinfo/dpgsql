/// Timezone utilities for handling PostgreSQL timestamp types correctly.
///
/// Solves the Dart DateTime Linux timezone issue where dates before 2020
/// return incorrect timezone offsets due to historical timezone transitions.
/// See: https://github.com/dart-lang/sdk/issues/56312
class TimezoneHelper {
  /// Fix DateTime to ignore past timezone transitions.
  ///
  /// On Linux, DateTime(2000) might have a different timezone offset than DateTime.now()
  /// due to historical DST/timezone changes. This causes incorrect timestamp decoding.
  ///
  /// This method adjusts the base DateTime to use the current timezone offset.
  static DateTime fixTimezoneTransition(DateTime baseDateTime) {
    final nowDt = DateTime.now();

    if (baseDateTime.timeZoneOffset != nowDt.timeZoneOffset) {
      final difference = baseDateTime.timeZoneOffset - nowDt.timeZoneOffset;
      return baseDateTime.add(difference);
    }

    return baseDateTime;
  }

  /// Decode PostgreSQL DATE value (days since 2000-01-01).
  ///
  /// PostgreSQL stores DATE as int32 days since 2000-01-01.
  /// This must be decoded in local time to match the stored value.
  static DateTime decodeDate(int days, {bool forceUTC = false}) {
    // Handle infinity values
    if (days == 2147483647 || days == -2147483648) {
      throw ArgumentError('Date value is infinity');
    }

    if (forceUTC) {
      return DateTime.utc(2000).add(Duration(days: days));
    }

    // Fix timezone transition issue for dates before current year
    final baseDt = fixTimezoneTransition(DateTime(2000));
    return baseDt.add(Duration(days: days));
  }

  /// Decode PostgreSQL TIMESTAMP (without timezone) value.
  ///
  /// PostgreSQL stores TIMESTAMP as int64 microseconds since 2000-01-01 00:00:00.
  /// This must be decoded in local time to preserve the stored value.
  static DateTime decodeTimestamp(int microseconds, {bool forceUTC = false}) {
    // Handle infinity values
    if (microseconds == 9223372036854775807 ||
        microseconds == -9223372036854775808) {
      throw ArgumentError('Timestamp value is infinity');
    }

    if (forceUTC) {
      return DateTime.utc(2000).add(Duration(microseconds: microseconds));
    }

    // Fix timezone transition issue for timestamps before current year
    final baseDt = fixTimezoneTransition(DateTime(2000));
    return baseDt.add(Duration(microseconds: microseconds));
  }

  /// Decode PostgreSQL TIMESTAMPTZ (with timezone) value.
  ///
  /// PostgreSQL stores TIMESTAMPTZ as int64 microseconds since 2000-01-01 00:00:00 UTC.
  /// This is always in UTC, so conversion to local time is straightforward.
  static DateTime decodeTimestampTz(int microseconds, {bool forceUTC = false}) {
    // Handle infinity values
    if (microseconds == 9223372036854775807 ||
        microseconds == -9223372036854775808) {
      throw ArgumentError('Timestamptz value is infinity');
    }

    final utcDateTime =
        DateTime.utc(2000).add(Duration(microseconds: microseconds));

    if (forceUTC) {
      return utcDateTime;
    }

    // Convert to local time
    return utcDateTime.toLocal();
  }

  /// Encode DateTime to PostgreSQL DATE format (days since 2000-01-01).
  static int encodeDate(DateTime dateTime, {bool treatAsUTC = false}) {
    final epoch = DateTime.utc(2000, 1, 1);
    final targetDate = treatAsUTC
        ? dateTime.toUtc()
        : DateTime(dateTime.year, dateTime.month, dateTime.day);

    final utcTarget =
        DateTime.utc(targetDate.year, targetDate.month, targetDate.day);
    return utcTarget.difference(epoch).inDays;
  }

  /// Encode DateTime to PostgreSQL TIMESTAMP format (microseconds since 2000-01-01).
  static int encodeTimestamp(DateTime dateTime, {bool treatAsUTC = false}) {
    final epoch = treatAsUTC ? DateTime.utc(2000, 1, 1) : DateTime(2000, 1, 1);

    // Fix timezone transition if needed
    final fixedEpoch = treatAsUTC ? epoch : fixTimezoneTransition(epoch);

    return dateTime.difference(fixedEpoch).inMicroseconds;
  }

  /// Encode DateTime to PostgreSQL TIMESTAMPTZ format (microseconds since 2000-01-01 UTC).
  static int encodeTimestampTz(DateTime dateTime) {
    final epoch = DateTime.utc(2000, 1, 1);
    final utcDateTime = dateTime.toUtc();
    return utcDateTime.difference(epoch).inMicroseconds;
  }
}
