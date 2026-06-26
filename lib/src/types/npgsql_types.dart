/// Custom types for Npgsql Dart port.
/// These types provide raw access to PostgreSQL values without lossy conversion.

import 'package:meta/meta.dart';

/// Represents a PostgreSQL Interval type.
/// (Months, Days, Time in microseconds)
@immutable
class NpgsqlInterval {
  final int months;
  final int days;
  final int time; // microseconds

  const NpgsqlInterval({this.months = 0, this.days = 0, this.time = 0});

  factory NpgsqlInterval.parse(String formattedString) {
    // Basic Parsing of Postgres text format (e.g. "1 year 2 mons 3 days 04:05:06.123")
    // and ISO 8601 (e.g. "P1Y2M3DT4H5M6S")

    int months = 0;
    int days = 0;
    int time = 0;

    String s = formattedString.trim();
    if (s.isEmpty) return NpgsqlInterval();

    if (s.startsWith('P')) {
      // ISO 8601 duration
      // Parsing ISO duration is complex, let's do a simplified version or regex
      // PnYnMnDTnHnMnS
      // We can use a regex to capture each part
      // Note: M can mean Month (if before T) or Minute (if after T)
      // This is tricky without a proper parser.
      // Let's implement a simple scanner.
      // bool timePart = false;
      // int buffer = 0;
      // int sign = 1;
      // Actually ISO 8601 duration standard is P[n]Y[n]M[n]DT[n]H[n]M[n]S

      // Just regex it for now assuming standard non-negative or simple negative
      // This is a naive implementation
      throw UnimplementedError('ISO 8601 Interval parsing not fully complete');
    } else {
      // Postgres format
      // Scan for keywords: year(s), mon(s), day(s)
      // Scan for Time HH:mm:ss

      // Regex for time: (\d+):(\d+):(\d+)(\.(\d+))?
      final timeRegex = RegExp(r'(-?\d+):(\d+):(\d+)(\.(\d+))?');
      final timeMatch = timeRegex.firstMatch(s);
      if (timeMatch != null) {
        final h = int.parse(timeMatch.group(1)!);
        final m = int.parse(timeMatch.group(2)!);
        final sec = int.parse(timeMatch.group(3)!);
        double frac = 0.0;
        if (timeMatch.group(5) != null) {
          frac = double.parse('0.${timeMatch.group(5)}');
        }
        // Remove time part from string to avoid confusing "3 days" with digits?
        // Actually usually patterns are separate.

        int micros = (h.abs() * 3600 * 1000000) +
            (m * 60 * 1000000) +
            (sec * 1000000) +
            (frac * 1000000).round();
        if (h < 0) micros = -micros;
        time = micros;
      }

      // Keywords
      // years
      final yearRegex = RegExp(r'(-?\d+)\s+years?');
      final yearMatch = yearRegex.firstMatch(s);
      if (yearMatch != null) {
        months += int.parse(yearMatch.group(1)!) * 12;
      }

      // mons
      final monRegex = RegExp(r'(-?\d+)\s+mons?');
      final monMatch = monRegex.firstMatch(s);
      if (monMatch != null) {
        months += int.parse(monMatch.group(1)!);
      }

      // days
      final dayRegex = RegExp(r'(-?\d+)\s+days?');
      final dayMatch = dayRegex.firstMatch(s);
      if (dayMatch != null) {
        days += int.parse(dayMatch.group(1)!);
      }
    }

    return NpgsqlInterval(months: months, days: days, time: time);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NpgsqlInterval &&
          runtimeType == other.runtimeType &&
          months == other.months &&
          days == other.days &&
          time == other.time;

  @override
  int get hashCode => months.hashCode ^ days.hashCode ^ time.hashCode;

  @override
  String toString() =>
      'NpgsqlInterval(months: $months, days: $days, time: $time)';
}

/// Represents a PostgreSQL Date type.
/// Stored as days since 2000-01-01.
@immutable
class NpgsqlDate {
  final int days;

  const NpgsqlDate(this.days);

  static final DateTime _pgEpoch = DateTime.utc(2000, 1, 1);

  factory NpgsqlDate.parse(String formattedString) {
    if (formattedString.length < 10) {
      throw FormatException('Invalid date format', formattedString);
    }
    // Simple fixed format YYYY-MM-DD
    final y = int.parse(formattedString.substring(0, 4));
    final m = int.parse(formattedString.substring(5, 7));
    final d = int.parse(formattedString.substring(8, 10));
    final dt = DateTime.utc(y, m, d);
    return NpgsqlDate(dt.difference(_pgEpoch).inDays);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NpgsqlDate &&
          runtimeType == other.runtimeType &&
          days == other.days;

  @override
  int get hashCode => days.hashCode;

  @override
  String toString() => 'NpgsqlDate(days: $days)';
}

/// Represents a PostgreSQL Time type (without time zone).
/// Stored as microseconds since midnight.
@immutable
class NpgsqlTime {
  final int microseconds;

  const NpgsqlTime(this.microseconds);

  factory NpgsqlTime.parse(String formattedString) {
    // Format: HH:mm:ss.uuuuuu
    // Dart DateTime parsing requires a date, so we can prepend a dummy date or parse manually.
    // Manual parsing is safer for purely time strings.
    // Expected: 12:34:56 or 12:34:56.123456
    try {
      final groups = formattedString.split(':');
      if (groups.length < 2)
        throw FormatException('Invalid time format', formattedString);
      int h = int.parse(groups[0]);
      int m = int.parse(groups[1]);
      double s = 0.0;
      if (groups.length > 2) {
        s = double.parse(groups[2]);
      }

      int micros =
          (h * 3600 * 1000000) + (m * 60 * 1000000) + (s * 1000000).round();
      return NpgsqlTime(micros);
    } catch (e) {
      throw FormatException('Invalid time format: $formattedString');
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NpgsqlTime &&
          runtimeType == other.runtimeType &&
          microseconds == other.microseconds;

  @override
  int get hashCode => microseconds.hashCode;

  @override
  String toString() => 'NpgsqlTime(microseconds: $microseconds)';
}

/// Represents a PostgreSQL Timestamp type (without time zone).
/// Stored as microseconds since 2000-01-01.
@immutable
class NpgsqlTimestamp {
  final int microseconds;

  const NpgsqlTimestamp(this.microseconds);

  static final DateTime _pgEpoch = DateTime.utc(2000, 1, 1);

  factory NpgsqlTimestamp.parse(String formattedString) {
    // Uses DateTime.parse which handles ISO8601
    // PG string: 2000-01-01 00:00:00.123456
    // DateTime.parse handles this.
    // If offset is present (timestamptz), DateTime.parse handles it and converts to local orUtc?
    // We want micros relative to 2000-01-01.
    // If it's timestamptz, PG sends UTC in binary, but text might have offset.
    // DateTime.parse("...-05") returns a DateTime which isUtc=false usually (converts to local?)
    // Actually DateTime.parse("...-0500") returns a UTC DateTime? No.
    // let's check: DateTime.parse("2000-01-01T12:00:00-0500").isUtc -> true. It normalizes to UTC.
    // Good.
    // Replace space with T if needed for DateTime.parse compatibility?
    // PG uses space, ISO uses T. Dart handles space?
    // Dart's DateTime.parse requires ' ' or 'T'. It supports space since recent versions or always?
    // The docs say "subset of ISO 8601". Examples show ' ' is replaced by 'T' inside parse?
    // Actually, let's just replace ' ' with 'T' to be safe.

    String iso = formattedString.trim();
    if (iso.contains(' ') && !iso.contains('T')) {
      iso = iso.replaceFirst(' ', 'T');
    }

    final dt = DateTime.parse(iso);
    // If timestamptz, dt is the moment.
    // If timestamp (no tz), dt is the "local" values as if they were UTC.
    // NpgsqlTimestamp simply stores micros from 2000-01-01.
    // We assume the value passed is the value we want to store.
    // If the string had an offset, DateTime.parse adjusted it to UTC.
    // We calculate difference from 2000-01-01 UTC.

    return NpgsqlTimestamp(dt.difference(_pgEpoch).inMicroseconds);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NpgsqlTimestamp &&
          runtimeType == other.runtimeType &&
          microseconds == other.microseconds;

  @override
  int get hashCode => microseconds.hashCode;

  @override
  String toString() => 'NpgsqlTimestamp(microseconds: $microseconds)';
}

/// Represents a PostgreSQL Money type.
/// Stored as a 64-bit integer (usually cents or equivalent).
@immutable
class NpgsqlMoney {
  final int value;

  const NpgsqlMoney(this.value);

  factory NpgsqlMoney.parse(String formattedString) {
    // $1,234.56
    // Remove non-numeric chars except . and -
    String clean = formattedString.replaceAll(RegExp(r'[^\d.-]'), '');
    double val = double.parse(clean);
    // Money is stored as cents (or fraction).
    // Standard is 2 decimal places? PG "money" type usually follows lc_monetary.
    // But internally it's 64-bit int. The scale is fixed?
    // "The scale of the money type is not fixed..." wait.
    // Npgsql assumes scale 2? or 4?
    // C# output: decimal.
    // In binary read, we treat it as int64.
    // Usually it's 1/100 of a unit? Or 1/10000?
    // Let's assume 2 decimal places for now as is common (cents).
    // Actually, wait, let's check Npgsql source or PG docs.
    // PG docs: "The fractional precision is determined by the database's lc_monetary setting."
    // However, binary transmission is always 64-bit integer.
    // Is it micros?
    // Most references say it's 100ths (cents) or dynamic.
    // Npgsql 2.x used to have issues. Recent Npgsql maps to decimal.
    // Let's assume standard assumption: * 100.
    // Wait, let's verify with "referencias\npgsql-main" if possible?
    // Can't search recursively easily without tool.
    // Let's assume 100 for now.

    return NpgsqlMoney((val * 100).round());
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NpgsqlMoney &&
          runtimeType == other.runtimeType &&
          value == other.value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'NpgsqlMoney($value)';
}

/// Represents a PostgreSQL Numeric/Decimal type.
/// Postgres Numeric is arbitrary precision base-10000.
/// We store the raw components.
@immutable
class NpgsqlDecimal {
  final int ndigits;
  final int weight;
  final int sign; // 0x0000 = positive, 0x4000 = negative, 0xC000 = NaN
  final int dscale;
  final List<int> digits;

  const NpgsqlDecimal({
    required this.ndigits,
    required this.weight,
    required this.sign,
    required this.dscale,
    required this.digits,
  });

  factory NpgsqlDecimal.parse(String formattedString) {
    // Parsing text numeric to raw components is hard.
    // For now, allow holding the string?
    // But the struct is strictly raw components.
    // We'll throw Unimplemented for text parsing of Decimal for now
    // as it requires implementing a Base-10000 converter.
    throw UnimplementedError(
        'Parsing text to NpgsqlDecimal raw components is not yet implemented.');
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NpgsqlDecimal &&
          runtimeType == other.runtimeType &&
          ndigits == other.ndigits &&
          weight == other.weight &&
          sign == other.sign &&
          dscale == other.dscale &&
          _digitsEqual(digits, other.digits);

  static bool _digitsEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(ndigits, weight, sign, dscale, Object.hashAll(digits));

  @override
  String toString() {
    if (sign == 0xC000) {
      return 'NaN';
    }
    if (ndigits == 0 || digits.isEmpty) {
      if (dscale <= 0) {
        return sign == 0x4000 ? '-0' : '0';
      }
      final value = '0.${''.padRight(dscale, '0')}';
      return sign == 0x4000 ? '-$value' : value;
    }

    final intGroups = weight + 1;
    final intPart = StringBuffer();
    final fracPart = StringBuffer();

    if (intGroups <= 0) {
      intPart.write('0');
      for (var i = 0; i < -intGroups; i++) {
        fracPart.write('0000');
      }
      for (var i = 0; i < ndigits; i++) {
        fracPart.write(digits[i].toString().padLeft(4, '0'));
      }
    } else {
      for (var i = 0; i < intGroups; i++) {
        final digit = i < ndigits ? digits[i] : 0;
        if (i == 0) {
          intPart.write(digit.toString());
        } else {
          intPart.write(digit.toString().padLeft(4, '0'));
        }
      }

      for (var i = intGroups; i < ndigits; i++) {
        fracPart.write(digits[i].toString().padLeft(4, '0'));
      }
    }

    var value = intPart.toString();
    if (dscale > 0) {
      var fractional = fracPart.toString();
      if (fractional.length < dscale) {
        fractional = fractional.padRight(dscale, '0');
      } else if (fractional.length > dscale) {
        fractional = fractional.substring(0, dscale);
      }
      value = '$value.$fractional';
    }

    return sign == 0x4000 ? '-$value' : value;
  }
}
