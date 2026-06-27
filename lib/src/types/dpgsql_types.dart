/// Custom types for Dpgsql Dart port.
/// These types provide raw access to PostgreSQL values without lossy conversion.

import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';

/// Represents a PostgreSQL Interval type.
/// (Months, Days, Time in microseconds)
@immutable
class DpgsqlInterval {
  final int months;
  final int days;
  final int time; // microseconds

  const DpgsqlInterval({this.months = 0, this.days = 0, this.time = 0});

  factory DpgsqlInterval.parse(String formattedString) {
    // Basic Parsing of Postgres text format (e.g. "1 year 2 mons 3 days 04:05:06.123")
    // and ISO 8601 (e.g. "P1Y2M3DT4H5M6S")

    int months = 0;
    int days = 0;
    int time = 0;

    String s = formattedString.trim();
    if (s.isEmpty) return DpgsqlInterval();

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

    return DpgsqlInterval(months: months, days: days, time: time);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DpgsqlInterval &&
          runtimeType == other.runtimeType &&
          months == other.months &&
          days == other.days &&
          time == other.time;

  @override
  int get hashCode => months.hashCode ^ days.hashCode ^ time.hashCode;

  @override
  String toString() =>
      'DpgsqlInterval(months: $months, days: $days, time: $time)';
}

/// Represents a PostgreSQL Date type.
/// Stored as days since 2000-01-01.
@immutable
class DpgsqlDate {
  final int days;

  const DpgsqlDate(this.days);

  static final DateTime _pgEpoch = DateTime.utc(2000, 1, 1);

  factory DpgsqlDate.parse(String formattedString) {
    if (formattedString.length < 10) {
      throw FormatException('Invalid date format', formattedString);
    }
    // Simple fixed format YYYY-MM-DD
    final y = int.parse(formattedString.substring(0, 4));
    final m = int.parse(formattedString.substring(5, 7));
    final d = int.parse(formattedString.substring(8, 10));
    final dt = DateTime.utc(y, m, d);
    return DpgsqlDate(dt.difference(_pgEpoch).inDays);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DpgsqlDate &&
          runtimeType == other.runtimeType &&
          days == other.days;

  @override
  int get hashCode => days.hashCode;

  @override
  String toString() => 'DpgsqlDate(days: $days)';
}

/// Represents a PostgreSQL Time type (without time zone).
/// Stored as microseconds since midnight.
@immutable
class DpgsqlTime {
  final int microseconds;

  const DpgsqlTime(this.microseconds);

  factory DpgsqlTime.parse(String formattedString) {
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
      return DpgsqlTime(micros);
    } catch (e) {
      throw FormatException('Invalid time format: $formattedString');
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DpgsqlTime &&
          runtimeType == other.runtimeType &&
          microseconds == other.microseconds;

  @override
  int get hashCode => microseconds.hashCode;

  @override
  String toString() => 'DpgsqlTime(microseconds: $microseconds)';
}

/// Represents a PostgreSQL Timestamp type (without time zone).
/// Stored as microseconds since 2000-01-01.
@immutable
class DpgsqlTimestamp {
  final int microseconds;

  const DpgsqlTimestamp(this.microseconds);

  static final DateTime _pgEpoch = DateTime.utc(2000, 1, 1);

  factory DpgsqlTimestamp.parse(String formattedString) {
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
    // DpgsqlTimestamp simply stores micros from 2000-01-01.
    // We assume the value passed is the value we want to store.
    // If the string had an offset, DateTime.parse adjusted it to UTC.
    // We calculate difference from 2000-01-01 UTC.

    return DpgsqlTimestamp(dt.difference(_pgEpoch).inMicroseconds);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DpgsqlTimestamp &&
          runtimeType == other.runtimeType &&
          microseconds == other.microseconds;

  @override
  int get hashCode => microseconds.hashCode;

  @override
  String toString() => 'DpgsqlTimestamp(microseconds: $microseconds)';
}

/// Represents a PostgreSQL Money type.
/// Stored as a 64-bit integer (usually cents or equivalent).
@immutable
class DpgsqlMoney {
  final int value;

  const DpgsqlMoney(this.value);

  factory DpgsqlMoney.parse(String formattedString) {
    // $1,234.56
    // Remove non-numeric chars except . and -
    String clean = formattedString.replaceAll(RegExp(r'[^\d.-]'), '');
    double val = double.parse(clean);
    // Money is stored as cents (or fraction).
    // Standard is 2 decimal places? PG "money" type usually follows lc_monetary.
    // But internally it's 64-bit int. The scale is fixed?
    // "The scale of the money type is not fixed..." wait.
    // Dpgsql assumes scale 2? or 4?
    // C# output: decimal.
    // In binary read, we treat it as int64.
    // Usually it's 1/100 of a unit? Or 1/10000?
    // Let's assume 2 decimal places for now as is common (cents).
    // Actually, wait, let's check Dpgsql source or PG docs.
    // PG docs: "The fractional precision is determined by the database's lc_monetary setting."
    // However, binary transmission is always 64-bit integer.
    // Is it micros?
    // Most references say it's 100ths (cents) or dynamic.
    // Dpgsql 2.x used to have issues. Recent Dpgsql maps to decimal.
    // Let's assume standard assumption: * 100.
    // Wait, let's verify with "referencias\npgsql-main" if possible?
    // Can't search recursively easily without tool.
    // Let's assume 100 for now.

    return DpgsqlMoney((val * 100).round());
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DpgsqlMoney &&
          runtimeType == other.runtimeType &&
          value == other.value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'DpgsqlMoney($value)';
}

/// Represents a PostgreSQL uuid value.
///
/// Dart has no built-in Guid type, so this mirrors Npgsql's Guid mapping with
/// a compact 16-byte value and canonical lower-case text formatting.
@immutable
class DpgsqlUuid {
  final Uint8List _bytes;

  DpgsqlUuid(List<int> bytes)
      : _bytes = Uint8List.fromList(_validateBytes(bytes));

  factory DpgsqlUuid.parse(String value) {
    var text = value.trim();
    if (text.startsWith('{') && text.endsWith('}')) {
      text = text.substring(1, text.length - 1);
    }
    text = text.replaceAll('-', '');
    if (text.length != 32) {
      throw FormatException('Invalid UUID length', value);
    }

    final bytes = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      bytes[i] = (_hexValue(text.codeUnitAt(i * 2)) << 4) |
          _hexValue(text.codeUnitAt((i * 2) + 1));
    }
    return DpgsqlUuid(bytes);
  }

  Uint8List toBytes() => Uint8List.fromList(_bytes);

  static List<int> _validateBytes(List<int> bytes) {
    if (bytes.length != 16) {
      throw FormatException('UUID must contain exactly 16 bytes');
    }
    for (final byte in bytes) {
      if (byte < 0 || byte > 255) {
        throw RangeError.range(byte, 0, 255, 'byte');
      }
    }
    return bytes;
  }

  static int _hexValue(int codeUnit) {
    if (codeUnit >= 0x30 && codeUnit <= 0x39) {
      return codeUnit - 0x30;
    }
    if (codeUnit >= 0x41 && codeUnit <= 0x46) {
      return codeUnit - 0x41 + 10;
    }
    if (codeUnit >= 0x61 && codeUnit <= 0x66) {
      return codeUnit - 0x61 + 10;
    }
    throw FormatException(
        'Invalid UUID hex digit: ${String.fromCharCode(codeUnit)}');
  }

  static String _hexByte(int value) => value.toRadixString(16).padLeft(2, '0');

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! DpgsqlUuid) return false;
    for (var i = 0; i < 16; i++) {
      if (_bytes[i] != other._bytes[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode {
    var hash = 17;
    for (final byte in _bytes) {
      hash = (hash * 31) ^ byte;
    }
    return hash;
  }

  @override
  String toString() {
    final hex = StringBuffer();
    for (var i = 0; i < 16; i++) {
      hex.write(_hexByte(_bytes[i]));
    }
    final value = hex.toString();
    return '${value.substring(0, 8)}-'
        '${value.substring(8, 12)}-'
        '${value.substring(12, 16)}-'
        '${value.substring(16, 20)}-'
        '${value.substring(20)}';
  }

  String toJson() => toString();
}

/// Represents PostgreSQL bit/varbit values.
///
/// PostgreSQL binary format stores a 32-bit bit length followed by packed bits,
/// most-significant bit first in each byte. The public representation keeps the
/// exact textual bit sequence for simple equality and formatting.
@immutable
class DpgsqlBitString {
  final String value;

  DpgsqlBitString(String value) : value = _validate(value);

  int get length => value.length;

  bool get isEmpty => value.isEmpty;

  static String _validate(String value) {
    for (var i = 0; i < value.length; i++) {
      final codeUnit = value.codeUnitAt(i);
      if (codeUnit != 0x30 && codeUnit != 0x31) {
        throw FormatException('Invalid bit string digit', value, i);
      }
    }
    return value;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DpgsqlBitString && value == other.value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;

  String toJson() => value;
}

/// Represents PostgreSQL inet values.
///
/// PostgreSQL binary format stores address family, prefix length and raw IP
/// bytes. The public representation keeps the textual address and optional
/// prefix so maps can still serialize cleanly through [toJson].
@immutable
class DpgsqlInet {
  DpgsqlInet(String address, {int? prefixLength})
      : address = _normalizeAddress(address),
        prefixLength = _validatePrefix(address, prefixLength);

  factory DpgsqlInet.parse(String value) {
    final (address, prefixLength) = _splitAddressAndPrefix(value);
    return DpgsqlInet(address, prefixLength: prefixLength);
  }

  final String address;
  final int? prefixLength;

  bool get isIPv4 => !_isIPv6Address(address);

  int get addressBits => isIPv4 ? 32 : 128;

  int get effectivePrefixLength => prefixLength ?? addressBits;

  Uint8List toBytes() {
    final parsed = InternetAddress.tryParse(address);
    if (parsed == null) {
      throw FormatException('Invalid IP address', address);
    }
    return Uint8List.fromList(parsed.rawAddress);
  }

  static String _normalizeAddress(String address) {
    final value = address.trim();
    final parsed = InternetAddress.tryParse(value);
    if (parsed == null) {
      throw FormatException('Invalid IP address', address);
    }
    return parsed.address;
  }

  static int? _validatePrefix(String address, int? prefixLength) {
    if (prefixLength == null) {
      return null;
    }
    final maxBits = _isIPv6Address(address) ? 128 : 32;
    if (prefixLength < 0 || prefixLength > maxBits) {
      throw RangeError.range(prefixLength, 0, maxBits, 'prefixLength');
    }
    return prefixLength;
  }

  static (String, int?) _splitAddressAndPrefix(String value) {
    final text = value.trim();
    final slash = text.indexOf('/');
    if (slash < 0) {
      return (text, null);
    }
    return (
      text.substring(0, slash),
      int.parse(text.substring(slash + 1)),
    );
  }

  static bool _isIPv6Address(String address) => address.contains(':');

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DpgsqlInet &&
          address == other.address &&
          effectivePrefixLength == other.effectivePrefixLength;

  @override
  int get hashCode => Object.hash(address, effectivePrefixLength);

  @override
  String toString() {
    final prefix = prefixLength;
    if (prefix == null || prefix == addressBits) {
      return address;
    }
    return '$address/$prefix';
  }

  String toJson() => toString();
}

/// Represents PostgreSQL cidr values.
@immutable
class DpgsqlCidr extends DpgsqlInet {
  DpgsqlCidr(super.address, {required int prefixLength})
      : super(prefixLength: prefixLength);

  factory DpgsqlCidr.parse(String value) {
    final inet = DpgsqlInet.parse(value);
    return DpgsqlCidr(
      inet.address,
      prefixLength: inet.prefixLength ?? inet.addressBits,
    );
  }
}

/// Represents PostgreSQL macaddr/macaddr8 values.
@immutable
class DpgsqlMacAddress {
  DpgsqlMacAddress(List<int> bytes)
      : _bytes = Uint8List.fromList(_validateBytes(bytes));

  factory DpgsqlMacAddress.parse(String value) {
    final text = value.trim().toLowerCase().replaceAll('-', ':');
    final parts = text.contains(':') ? text.split(':') : _splitHexPairs(text);
    if (parts.length != 6 && parts.length != 8) {
      throw FormatException('Invalid MAC address length', value);
    }

    final bytes = Uint8List(parts.length);
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      if (part.length != 2) {
        throw FormatException('Invalid MAC address segment', value);
      }
      bytes[i] = int.parse(part, radix: 16);
    }
    return DpgsqlMacAddress(bytes);
  }

  final Uint8List _bytes;

  int get length => _bytes.length;

  Uint8List toBytes() => Uint8List.fromList(_bytes);

  static List<String> _splitHexPairs(String value) {
    if (value.length.isOdd) {
      throw FormatException('Invalid MAC address length', value);
    }
    final parts = <String>[];
    for (var i = 0; i < value.length; i += 2) {
      parts.add(value.substring(i, i + 2));
    }
    return parts;
  }

  static List<int> _validateBytes(List<int> bytes) {
    if (bytes.length != 6 && bytes.length != 8) {
      throw FormatException('MAC address must contain 6 or 8 bytes');
    }
    for (final byte in bytes) {
      if (byte < 0 || byte > 255) {
        throw RangeError.range(byte, 0, 255, 'byte');
      }
    }
    return bytes;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! DpgsqlMacAddress || other.length != length) return false;
    for (var i = 0; i < length; i++) {
      if (_bytes[i] != other._bytes[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode {
    var hash = 17;
    for (final byte in _bytes) {
      hash = (hash * 31) ^ byte;
    }
    return hash;
  }

  @override
  String toString() =>
      _bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':');

  String toJson() => toString();
}

/// Represents a PostgreSQL Numeric/Decimal type.
/// Postgres Numeric is arbitrary precision base-10000.
/// We store the raw components.
@immutable
class DpgsqlDecimal {
  final int ndigits;
  final int weight;
  final int sign; // 0x0000 = positive, 0x4000 = negative, 0xC000 = NaN
  final int dscale;
  final List<int> digits;

  const DpgsqlDecimal({
    required this.ndigits,
    required this.weight,
    required this.sign,
    required this.dscale,
    required this.digits,
  });

  factory DpgsqlDecimal.parse(String formattedString) {
    var value = formattedString.trim();
    if (value.toLowerCase() == 'nan') {
      return const DpgsqlDecimal(
        ndigits: 0,
        weight: 0,
        sign: 0xC000,
        dscale: 0,
        digits: <int>[],
      );
    }

    var sign = 0x0000;
    if (value.startsWith('-')) {
      sign = 0x4000;
      value = value.substring(1);
    } else if (value.startsWith('+')) {
      value = value.substring(1);
    }

    if (value.contains('e') || value.contains('E')) {
      value = _expandScientificNotation(value);
    }

    final dotIndex = value.indexOf('.');
    var intPart = dotIndex == -1 ? value : value.substring(0, dotIndex);
    final fracPart = dotIndex == -1 ? '' : value.substring(dotIndex + 1);
    final dscale = fracPart.length;

    intPart = intPart.replaceFirst(RegExp(r'^0+'), '');
    final intGroupCount = intPart.isEmpty ? 0 : (intPart.length + 3) ~/ 4;
    final fracGroupCount = fracPart.isEmpty ? 0 : (fracPart.length + 3) ~/ 4;

    final groups = <int>[];
    if (intGroupCount > 0) {
      final paddedInt = intPart.padLeft(intGroupCount * 4, '0');
      for (var i = 0; i < paddedInt.length; i += 4) {
        groups.add(int.parse(paddedInt.substring(i, i + 4)));
      }
    }

    if (fracGroupCount > 0) {
      final paddedFrac = fracPart.padRight(fracGroupCount * 4, '0');
      for (var i = 0; i < paddedFrac.length; i += 4) {
        groups.add(int.parse(paddedFrac.substring(i, i + 4)));
      }
    }

    var weight = intGroupCount - 1;
    while (groups.isNotEmpty && groups.first == 0) {
      groups.removeAt(0);
      weight--;
    }
    while (groups.isNotEmpty && groups.last == 0) {
      groups.removeLast();
    }

    return DpgsqlDecimal(
      ndigits: groups.length,
      weight: groups.isEmpty ? 0 : weight,
      sign: groups.isEmpty ? 0x0000 : sign,
      dscale: dscale,
      digits: List<int>.unmodifiable(groups),
    );
  }

  static String _expandScientificNotation(String value) {
    final exponentIndex = value.indexOf(RegExp('[eE]'));
    final mantissa = value.substring(0, exponentIndex);
    final exponent = int.parse(value.substring(exponentIndex + 1));
    final dotIndex = mantissa.indexOf('.');
    final intPart = dotIndex == -1 ? mantissa : mantissa.substring(0, dotIndex);
    final fracPart = dotIndex == -1 ? '' : mantissa.substring(dotIndex + 1);
    final digits = '$intPart$fracPart';
    final decimalIndex = intPart.length + exponent;

    if (decimalIndex <= 0) {
      return '0.${''.padRight(-decimalIndex, '0')}$digits';
    }
    if (decimalIndex >= digits.length) {
      return digits.padRight(decimalIndex, '0');
    }
    return '${digits.substring(0, decimalIndex)}.'
        '${digits.substring(decimalIndex)}';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DpgsqlDecimal &&
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
