import 'npgsql_db_type.dart';

/// Represents a parameter to a NpgsqlCommand.
/// Porting NpgsqlParameter.cs
class NpgsqlParameter {
  NpgsqlParameter([this.parameterName = '', this.value]);

  /// Gets or sets the name of the NpgsqlParameter.
  String parameterName;

  /// Gets or sets the value of the parameter.
  dynamic value;

  /// Gets or sets the NpgsqlDbType of the parameter.
  NpgsqlDbType? npgsqlDbType;

  /// Gets or sets the maximum size, in bytes, of the data within the column.
  int? size;

  /// Gets or sets the maximum number of digits used to represent the Value property.
  int? precision;

  /// Gets or sets the number of decimal places to which Value is resolved.
  int? scale;
}
