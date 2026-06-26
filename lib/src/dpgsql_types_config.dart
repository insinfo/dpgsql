import 'dart:convert';

/// Configuration for custom type handlers.
class DpgsqlTypesConfig {
  DpgsqlTypesConfig({
    this.useCustomDate = false,
    this.useCustomTimestamp = false,
    this.useCustomTime = false,
    this.useCustomInterval = false,
    this.useCustomDecimal = false,
    this.encoding = utf8,
  });

  /// Use DpgsqlDate instead of DateTime for PostgreSQL date type.
  final bool useCustomDate;

  /// Use DpgsqlTimestamp instead of DateTime for PostgreSQL timestamp types.
  final bool useCustomTimestamp;

  /// Use DpgsqlTime instead of DateTime for PostgreSQL time type.
  final bool useCustomTime;

  /// Use DpgsqlInterval for PostgreSQL interval type (always recommended).
  final bool useCustomInterval;

  /// Use DpgsqlDecimal instead of double for PostgreSQL numeric/decimal types.
  final bool useCustomDecimal;

  /// Character encoding for text types.
  final Encoding encoding;

  /// Create config with all custom types enabled.
  factory DpgsqlTypesConfig.allCustom({Encoding encoding = utf8}) {
    return DpgsqlTypesConfig(
      useCustomDate: true,
      useCustomTimestamp: true,
      useCustomTime: true,
      useCustomInterval: true,
      useCustomDecimal: true,
      encoding: encoding,
    );
  }

  /// Create config with only safe/recommended custom types.
  factory DpgsqlTypesConfig.recommended({Encoding encoding = utf8}) {
    return DpgsqlTypesConfig(
      useCustomDate: false,
      useCustomTimestamp: false,
      useCustomTime: false,
      useCustomInterval: true, // DpgsqlInterval is always better than Duration
      useCustomDecimal: false,
      encoding: encoding,
    );
  }
}
