/// Represents a parameter to a NpgsqlCommand.
/// Porting NpgsqlParameter.cs
class NpgsqlParameter {
  NpgsqlParameter([this.parameterName = '', this.value]);

  /// Gets or sets the name of the NpgsqlParameter.
  String parameterName;

  /// Gets or sets the value of the parameter.
  dynamic value;

  // TODO: NpgsqlDbType, DbType, Precision, Scale, Size, etc.
  // For now, we infer type from value or use text.
}
