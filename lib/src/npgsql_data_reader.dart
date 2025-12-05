import 'dart:async';

/// Provides a means of reading one or more forward-only streams of result sets obtained by executing a command at a PostgreSQL database.
/// Porting NpgsqlDataReader.cs
abstract class NpgsqlDataReader {
  /// Advances the NpgsqlDataReader to the next record.
  Future<bool> read();

  /// Gets the value of the specified column.
  dynamic operator [](dynamic index);

  /// Gets the number of columns in the current row.
  int get fieldCount;

  /// Gets the number of rows changed, inserted, or deleted by execution of the SQL statement.
  int get recordsAffected;

  /// Gets the column ordinal, given the name of the column.
  int getOrdinal(String name);

  /// Closes the NpgsqlDataReader object.
  Future<void> close();
}
