import '../utils/pg_timezone/pg_timezone.dart' as pg_tz;
import '../timezone_settings.dart';

/// Timezone utilities for handling PostgreSQL timestamp types correctly.
///
/// Solves the Dart DateTime Linux timezone issue where dates before 2020
/// return incorrect timezone offsets due to historical timezone transitions.
/// See: https://github.com/dart-lang/sdk/issues/56312
class TimezoneHelper {
  static const int _microsecondsPerDay = 86400000000;
  static const int _postgresUnixEpochMicroseconds = 946684800000000;
  static const int _dateInfinity = 2147483647;
  static const int _dateNegativeInfinity = -2147483648;
  static const int _timestampInfinity = 9223372036854775807;
  static const int _timestampNegativeInfinity = -9223372036854775808;

  static final DateTime _localTimestampEpoch =
      fixTimezoneTransition(DateTime(2000));
  static final int _localTimestampEpochMicroseconds =
      _localTimestampEpoch.microsecondsSinceEpoch;
  static final int _uncorrectedLocalTimestampEpochMicroseconds =
      DateTime(2000).microsecondsSinceEpoch;
  static final Map<String, pg_tz.Location> _locationCache =
      <String, pg_tz.Location>{};

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
  static DateTime? decodeDate(
    int days, {
    TimeZoneSettings timeZone = const TimeZoneSettings.utc(),
  }) {
    if (days == _dateInfinity || days == _dateNegativeInfinity) {
      return _handleInfinity('Date', timeZone);
    }

    if (timeZone.forceDecodeDateAsUTC) {
      return DateTime.fromMicrosecondsSinceEpoch(
        _postgresUnixEpochMicroseconds + (days * _microsecondsPerDay),
        isUtc: true,
      );
    }

    final baseMicros = timeZone.useCurrentOffsetForLocalTimestamp
        ? _localTimestampEpochMicroseconds
        : _uncorrectedLocalTimestampEpochMicroseconds;
    return DateTime.fromMicrosecondsSinceEpoch(
      baseMicros + (days * _microsecondsPerDay),
    );
  }

  static DateTime? decodeDateText(
    String value, {
    TimeZoneSettings timeZone = const TimeZoneSettings.utc(),
  }) {
    final fast = _parseIsoFields(value);
    if (fast != null) {
      return timeZone.forceDecodeDateAsUTC
          ? DateTime.utc(fast.year, fast.month, fast.day)
          : DateTime(fast.year, fast.month, fast.day);
    }
    if (_isInfinityText(value)) {
      return _handleInfinity('Date', timeZone);
    }
    final raw = DateTime.parse(_isoText(value));
    return timeZone.forceDecodeDateAsUTC
        ? DateTime.utc(raw.year, raw.month, raw.day)
        : DateTime(raw.year, raw.month, raw.day);
  }

  /// Decode PostgreSQL TIMESTAMP (without timezone) value.
  ///
  /// PostgreSQL stores TIMESTAMP as int64 microseconds since 2000-01-01 00:00:00.
  /// This must be decoded in local time to preserve the stored value.
  static DateTime? decodeTimestamp(
    int microseconds, {
    TimeZoneSettings timeZone = const TimeZoneSettings.utc(),
  }) {
    if (microseconds == _timestampInfinity ||
        microseconds == _timestampNegativeInfinity) {
      return _handleInfinity('Timestamp', timeZone);
    }

    if (timeZone.forceDecodeTimestampAsUTC) {
      return DateTime.fromMicrosecondsSinceEpoch(
        _postgresUnixEpochMicroseconds + microseconds,
        isUtc: true,
      );
    }

    final baseMicros = timeZone.useCurrentOffsetForLocalTimestamp
        ? _localTimestampEpochMicroseconds
        : _uncorrectedLocalTimestampEpochMicroseconds;
    return DateTime.fromMicrosecondsSinceEpoch(baseMicros + microseconds);
  }

  static DateTime? decodeTimestampText(
    String value, {
    TimeZoneSettings timeZone = const TimeZoneSettings.utc(),
  }) {
    final fast = _parseIsoFields(value);
    if (fast != null && fast.offsetSeconds == null) {
      final ms = fast.microsecond ~/ 1000;
      final us = fast.microsecond % 1000;
      return timeZone.forceDecodeTimestampAsUTC
          ? DateTime.utc(fast.year, fast.month, fast.day, fast.hour,
              fast.minute, fast.second, ms, us)
          : DateTime(fast.year, fast.month, fast.day, fast.hour, fast.minute,
              fast.second, ms, us);
    }
    if (_isInfinityText(value)) {
      return _handleInfinity('Timestamp', timeZone);
    }
    final raw = DateTime.parse(_isoText(value));
    return timeZone.forceDecodeTimestampAsUTC
        ? DateTime.utc(
            raw.year,
            raw.month,
            raw.day,
            raw.hour,
            raw.minute,
            raw.second,
            raw.millisecond,
            raw.microsecond,
          )
        : DateTime(
            raw.year,
            raw.month,
            raw.day,
            raw.hour,
            raw.minute,
            raw.second,
            raw.millisecond,
            raw.microsecond,
          );
  }

  /// Decode PostgreSQL TIMESTAMPTZ (with timezone) value.
  ///
  /// PostgreSQL stores TIMESTAMPTZ as int64 microseconds since 2000-01-01 00:00:00 UTC.
  /// This is always in UTC, so conversion to local time is straightforward.
  static DateTime? decodeTimestampTz(
    int microseconds, {
    TimeZoneSettings timeZone = const TimeZoneSettings.utc(),
  }) {
    if (microseconds == _timestampInfinity ||
        microseconds == _timestampNegativeInfinity) {
      return _handleInfinity('Timestamptz', timeZone);
    }

    final utcDateTime = DateTime.fromMicrosecondsSinceEpoch(
      _postgresUnixEpochMicroseconds + microseconds,
      isUtc: true,
    );

    if (timeZone.forceDecodeTimestamptzAsUTC) {
      return utcDateTime;
    }

    return _decodeTimestampTzAsConfiguredLocal(utcDateTime, timeZone);
  }

  static DateTime? decodeTimestampTzText(
    String value, {
    TimeZoneSettings timeZone = const TimeZoneSettings.utc(),
  }) {
    final fast = _parseIsoFields(value);
    if (fast != null && fast.offsetSeconds != null) {
      final utc = DateTime.utc(fast.year, fast.month, fast.day, fast.hour,
              fast.minute, fast.second, fast.microsecond ~/ 1000,
              fast.microsecond % 1000)
          .subtract(Duration(seconds: fast.offsetSeconds!));
      if (timeZone.forceDecodeTimestamptzAsUTC) return utc;
      return _decodeTimestampTzAsConfiguredLocal(utc, timeZone);
    }
    if (_isInfinityText(value)) {
      return _handleInfinity('Timestamptz', timeZone);
    }
    final raw = DateTime.parse(_isoText(value));
    if (timeZone.forceDecodeTimestamptzAsUTC) {
      return raw.toUtc();
    }
    return _decodeTimestampTzAsConfiguredLocal(raw.toUtc(), timeZone);
  }

  static DateTime _decodeTimestampTzAsConfiguredLocal(
    DateTime utcDateTime,
    TimeZoneSettings timeZone,
  ) {
    final timeZoneName = timeZone.value.trim();
    if (timeZoneName.isEmpty || timeZoneName.toLowerCase() == 'utc') {
      return utcDateTime;
    }

    if (!timeZone.useIanaTimeZoneDatabase) {
      return utcDateTime.toLocal();
    }

    final location = _resolvePgTimeZoneLocation(
      timeZoneName,
      timeZone.ianaTimeZoneDatabaseScope,
    );
    if (!timeZone.useCurrentOffsetForLocalTimestamp) {
      return pg_tz.TZDateTime.from(utcDateTime, location);
    }

    var shifted = utcDateTime;
    final offset = location.currentTimeZone.offset;
    if (offset != 0) {
      shifted = shifted.add(Duration(milliseconds: offset));
    }

    return pg_tz.TZDateTime(
      location,
      shifted.year,
      shifted.month,
      shifted.day,
      shifted.hour,
      shifted.minute,
      shifted.second,
      shifted.millisecond,
      shifted.microsecond,
    );
  }

  static pg_tz.Location _resolvePgTimeZoneLocation(
    String value,
    pg_tz.PgTimeZoneDatabaseScope scope,
  ) {
    final key = '${scope.name}:${value.toLowerCase()}';
    final cached = _locationCache[key];
    if (cached != null) {
      return cached;
    }

    final location = pg_tz.getLocation(value.toLowerCase(), scope: scope);
    _locationCache[key] = location;
    return location;
  }

  static DateTime? _handleInfinity(String typeName, TimeZoneSettings timeZone) {
    if (timeZone.throwOnDateTimeInfinity) {
      throw ArgumentError('$typeName value is infinity');
    }
    return null;
  }

  /// PostgreSQL's text form of a date or timestamp as ISO 8601 for
  /// [DateTime.parse]. Years before Christ (`0044-03-15 BC`) used to throw a
  /// FormatException; ISO 8601 counts them as 0 (1 BC), -1 (2 BC), ...
  /// The fields of `YYYY-MM-DD[ HH:MM:SS[.ffffff]][+HH[:MM[:SS]]]`, the
  /// text PostgreSQL sends with DateStyle ISO, read digit by digit; `null`
  /// for anything else (BC dates, infinity, years after 9999), which goes
  /// through [DateTime.parse]. `DateTime.parse` (a regular expression, then
  /// a second DateTime) took about 30 µs per value.
  static ({
    int year,
    int month,
    int day,
    int hour,
    int minute,
    int second,
    int microsecond,
    int? offsetSeconds,
  })? _parseIsoFields(String s) {
    final length = s.length;
    if (length < 10) return null;
    int digits(int start, int count) {
      var value = 0;
      for (var i = start; i < start + count; i++) {
        final d = s.codeUnitAt(i) - 0x30;
        if (d < 0 || d > 9) return -1;
        value = value * 10 + d;
      }
      return value;
    }

    final year = digits(0, 4);
    if (year < 0 || s.codeUnitAt(4) != 0x2d || s.codeUnitAt(7) != 0x2d) {
      return null;
    }
    final month = digits(5, 2);
    final day = digits(8, 2);
    if (month < 0 || day < 0) return null;
    var hour = 0, minute = 0, second = 0, microsecond = 0;
    int? offsetSeconds;
    var i = 10;
    if (i < length) {
      if (s.codeUnitAt(i) != 0x20 || length < 19) return null;
      hour = digits(11, 2);
      minute = digits(14, 2);
      second = digits(17, 2);
      if (hour < 0 ||
          minute < 0 ||
          second < 0 ||
          s.codeUnitAt(13) != 0x3a ||
          s.codeUnitAt(16) != 0x3a) {
        return null;
      }
      i = 19;
      if (i < length && s.codeUnitAt(i) == 0x2e) {
        i++;
        var count = 0;
        while (i < length) {
          final d = s.codeUnitAt(i) - 0x30;
          if (d < 0 || d > 9) break;
          if (count < 6) microsecond = microsecond * 10 + d;
          count++;
          i++;
        }
        if (count == 0) return null;
        for (; count < 6; count++) {
          microsecond *= 10;
        }
      }
      if (i < length) {
        final sign = s.codeUnitAt(i);
        if (sign != 0x2b && sign != 0x2d) return null;
        if (length < i + 3) return null;
        var offset = digits(i + 1, 2) * 3600;
        if (offset < 0) return null;
        i += 3;
        for (final unit in const [60, 1]) {
          if (i == length) break;
          if (s.codeUnitAt(i) != 0x3a || length < i + 3) return null;
          final part = digits(i + 1, 2);
          if (part < 0) return null;
          offset += part * unit;
          i += 3;
        }
        if (i != length) return null;
        offsetSeconds = sign == 0x2d ? -offset : offset;
      }
    }
    return (
      year: year,
      month: month,
      day: day,
      hour: hour,
      minute: minute,
      second: second,
      microsecond: microsecond,
      offsetSeconds: offsetSeconds,
    );
  }

  static String _isoText(String value) {
    var text = value.trim();
    if (text.endsWith(' BC')) {
      text = text.substring(0, text.length - 3);
      final year = RegExp(r'^\d+').firstMatch(text)!;
      final isoYear = int.parse(year[0]!) - 1;
      text = (isoYear == 0 ? '0000' : '-${'$isoYear'.padLeft(6, '0')}') +
          text.substring(year.end);
    }
    return text.replaceFirst(' ', 'T');
  }

  static bool _isInfinityText(String value) {
    final normalized = value.trim().toLowerCase();
    return normalized == 'infinity' || normalized == '-infinity';
  }

  /// Encode DateTime to PostgreSQL DATE format (days since 2000-01-01).
  static int encodeDate(
    DateTime dateTime, {
    TimeZoneSettings timeZone = const TimeZoneSettings.utc(),
  }) {
    final targetDate = timeZone.forceDecodeDateAsUTC
        ? dateTime.toUtc()
        : DateTime(dateTime.year, dateTime.month, dateTime.day);

    final utcTarget =
        DateTime.utc(targetDate.year, targetDate.month, targetDate.day);
    return (utcTarget.microsecondsSinceEpoch -
            _postgresUnixEpochMicroseconds) ~/
        _microsecondsPerDay;
  }

  /// Encode DateTime to PostgreSQL TIMESTAMP format (microseconds since 2000-01-01).
  static int encodeTimestamp(
    DateTime dateTime, {
    TimeZoneSettings timeZone = const TimeZoneSettings.utc(),
  }) {
    final epochMicros = timeZone.forceDecodeTimestampAsUTC
        ? _postgresUnixEpochMicroseconds
        : (timeZone.useCurrentOffsetForLocalTimestamp
            ? _localTimestampEpochMicroseconds
            : _uncorrectedLocalTimestampEpochMicroseconds);

    return dateTime.microsecondsSinceEpoch - epochMicros;
  }

  /// Encode DateTime to PostgreSQL TIMESTAMPTZ format (microseconds since 2000-01-01 UTC).
  static int encodeTimestampTz(DateTime dateTime) {
    final utcDateTime = dateTime.toUtc();
    return utcDateTime.microsecondsSinceEpoch - _postgresUnixEpochMicroseconds;
  }
}
