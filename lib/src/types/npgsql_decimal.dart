import 'dart:math' as math;

/// Represents a PostgreSQL NUMERIC/DECIMAL value with exact precision.
/// Unlike double, this maintains exact decimal precision without floating point errors.
class NpgsqlDecimal implements Comparable<NpgsqlDecimal> {
  /// The value as a scaled integer.
  /// For example, 123.45 with scale 2 is stored as 12345.
  final BigInt _value;

  /// Number of digits after the decimal point.
  final int scale;

  const NpgsqlDecimal._(this._value, this.scale);

  /// Create from a string representation (e.g., "123.45").
  factory NpgsqlDecimal.parse(String s) {
    if (s.isEmpty) throw FormatException('Empty decimal string');

    // Handle negative sign
    final isNegative = s.startsWith('-');
    final unsigned = isNegative ? s.substring(1) : s;

    // Split on decimal point
    final parts = unsigned.split('.');
    if (parts.length > 2) {
      throw FormatException('Invalid decimal format: $s');
    }

    final intPart = parts[0];
    final fracPart = parts.length > 1 ? parts[1] : '';
    final scale = fracPart.length;

    // Combine integer and fractional parts
    final combined = intPart + fracPart;
    var value = BigInt.parse(combined);

    if (isNegative) {
      value = -value;
    }

    return NpgsqlDecimal._(value, scale);
  }

  /// Create from double (may lose precision for some values).
  factory NpgsqlDecimal.fromDouble(double d, {int scale = 6}) {
    final multiplier = math.pow(10, scale).toInt();
    final scaled = (d * multiplier).round();
    return NpgsqlDecimal._(BigInt.from(scaled), scale);
  }

  /// Create from int.
  factory NpgsqlDecimal.fromInt(int i) {
    return NpgsqlDecimal._(BigInt.from(i), 0);
  }

  /// Create from BigInt with specific scale.
  factory NpgsqlDecimal.fromBigInt(BigInt value, int scale) {
    return NpgsqlDecimal._(value, scale);
  }

  /// Zero value.
  static final zero = NpgsqlDecimal._(BigInt.zero, 0);

  /// One value.
  static final one = NpgsqlDecimal._(BigInt.one, 0);

  /// Convert to double (may lose precision).
  double toDouble() {
    final divisor = math.pow(10, scale);
    return _value.toDouble() / divisor;
  }

  /// Convert to int (truncates fractional part).
  int toInt() {
    return (_value ~/ BigInt.from(math.pow(10, scale))).toInt();
  }

  /// Get the sign: -1 for negative, 0 for zero, 1 for positive.
  int get sign => _value.sign;

  /// Whether this value is zero.
  bool get isZero => _value == BigInt.zero;

  /// Whether this value is negative.
  bool get isNegative => _value.isNegative;

  /// Absolute value.
  NpgsqlDecimal abs() {
    return NpgsqlDecimal._(_value.abs(), scale);
  }

  /// Negate.
  NpgsqlDecimal operator -() {
    return NpgsqlDecimal._(-_value, scale);
  }

  /// Add.
  NpgsqlDecimal operator +(NpgsqlDecimal other) {
    final maxScale = math.max(scale, other.scale);
    final v1 = _rescale(maxScale);
    final v2 = other._rescale(maxScale);
    return NpgsqlDecimal._(v1 + v2, maxScale);
  }

  /// Subtract.
  NpgsqlDecimal operator -(NpgsqlDecimal other) {
    final maxScale = math.max(scale, other.scale);
    final v1 = _rescale(maxScale);
    final v2 = other._rescale(maxScale);
    return NpgsqlDecimal._(v1 - v2, maxScale);
  }

  /// Multiply.
  NpgsqlDecimal operator *(NpgsqlDecimal other) {
    return NpgsqlDecimal._(_value * other._value, scale + other.scale);
  }

  /// Divide.
  NpgsqlDecimal operator /(NpgsqlDecimal other) {
    if (other.isZero) throw ArgumentError('Division by zero');

    // Scale up numerator to maintain precision
    final newScale = scale + 6; // Add 6 digits of precision
    final scaledValue = _value * BigInt.from(math.pow(10, 6));
    final result = scaledValue ~/ other._value;

    return NpgsqlDecimal._(result, newScale);
  }

  /// Rescale to a different scale.
  BigInt _rescale(int newScale) {
    if (newScale == scale) return _value;
    if (newScale > scale) {
      final diff = newScale - scale;
      return _value * BigInt.from(math.pow(10, diff));
    } else {
      final diff = scale - newScale;
      return _value ~/ BigInt.from(math.pow(10, diff));
    }
  }

  @override
  int compareTo(NpgsqlDecimal other) {
    final maxScale = math.max(scale, other.scale);
    final v1 = _rescale(maxScale);
    final v2 = other._rescale(maxScale);
    return v1.compareTo(v2);
  }

  @override
  bool operator ==(Object other) {
    if (other is! NpgsqlDecimal) return false;
    final maxScale = math.max(scale, other.scale);
    return _rescale(maxScale) == other._rescale(maxScale);
  }

  @override
  int get hashCode => Object.hash(_rescale(6), scale);

  @override
  String toString() {
    if (scale == 0) return _value.toString();

    final str = _value.abs().toString().padLeft(scale + 1, '0');
    final intPart = str.substring(0, str.length - scale);
    final fracPart = str.substring(str.length - scale);

    final sign = _value.isNegative ? '-' : '';
    return '$sign$intPart.$fracPart';
  }
}
