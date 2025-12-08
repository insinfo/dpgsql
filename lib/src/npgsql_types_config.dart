import 'dart:convert';

/// Configuration for custom type handlers.
class NpgsqlTypesConfig {
  NpgsqlTypesConfig({
    this.useCustomDate = false,
    this.useCustomTimestamp = false,
    this.useCustomTime = false,
    this.useCustomInterval = false,
    this.useCustomDecimal = false,
    this.encoding = utf8,
  });

  /// Use NpgsqlDate instead of DateTime for PostgreSQL date type.
  final bool useCustomDate;

  /// Use NpgsqlTimestamp instead of DateTime for PostgreSQL timestamp types.
  final bool useCustomTimestamp;

  /// Use NpgsqlTime instead of DateTime for PostgreSQL time type.
  final bool useCustomTime;

  /// Use NpgsqlInterval for PostgreSQL interval type (always recommended).
  final bool useCustomInterval;

  /// Use NpgsqlDecimal instead of double for PostgreSQL numeric/decimal types.
  final bool useCustomDecimal;

  /// Character encoding for text types.
  final Encoding encoding;

  /// Create config with all custom types enabled.
  factory NpgsqlTypesConfig.allCustom({Encoding encoding = utf8}) {
    return NpgsqlTypesConfig(
      useCustomDate: true,
      useCustomTimestamp: true,
      useCustomTime: true,
      useCustomInterval: true,
      useCustomDecimal: true,
      encoding: encoding,
    );
  }

  /// Create config with only safe/recommended custom types.
  factory NpgsqlTypesConfig.recommended({Encoding encoding = utf8}) {
    return NpgsqlTypesConfig(
      useCustomDate: false,
      useCustomTimestamp: false,
      useCustomTime: false,
      useCustomInterval: true, // NpgsqlInterval is always better than Duration
      useCustomDecimal: false,
      encoding: encoding,
    );
  }
}
