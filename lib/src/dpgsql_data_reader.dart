import 'dart:async';

/// Provides a means of reading one or more forward-only streams of result sets obtained by executing a command at a PostgreSQL database.
/// Porting DpgsqlDataReader.cs
abstract class DpgsqlDataReader {
  /// Advances the DpgsqlDataReader to the next record.
  Future<bool> read();

  /// Gets the value of the specified column.
  dynamic operator [](dynamic index);

  /// Gets the value of the specified column by ordinal.
  dynamic getValue(int ordinal);

  /// Materializes the current row as a column-name keyed map.
  ///
  /// This allocates one map for the current row. Values are decoded with the
  /// same rules used by [getValue].
  Map<String, dynamic> toMap();

  /// Reads all remaining rows in the current result set as maps.
  ///
  /// This is intended for ORM-style integrations that naturally consume
  /// `Map<String, dynamic>` rows.
  Future<List<Map<String, dynamic>>> readAllMaps();

  /// Gets whether the specified column contains a database NULL.
  bool isDBNull(int ordinal);

  /// Gets the specified column as an int.
  int getInt(int ordinal);

  /// Gets the specified column as a String.
  String getString(int ordinal);

  /// Gets the specified column as a double.
  double getDouble(int ordinal);

  /// Gets the specified column as a bool.
  bool getBool(int ordinal);

  /// Gets the specified column as a DateTime.
  DateTime getDateTime(int ordinal);

  /// Gets the number of columns in the current row.
  int get fieldCount;

  /// Gets the number of rows changed, inserted, or deleted by execution of the SQL statement.
  int get recordsAffected;

  /// Gets the column ordinal, given the name of the column.
  int getOrdinal(String name);

  /// Advances the data reader to the next result, when reading the results of batch SQL statements.
  Future<bool> nextResult();

  /// Closes the DpgsqlDataReader object.
  Future<void> close();
}
