import 'dart:async';

import 'npgsql_connection.dart';
import 'npgsql_data_reader.dart';
import 'npgsql_parameter_collection.dart';
import 'npgsql_transaction.dart';

/// Represents a SQL statement or function (stored procedure) to execute against a PostgreSQL database.
/// Porting NpgsqlCommand.cs
class NpgsqlCommand {
  NpgsqlCommand([this.commandText = '', this.connection, this.transaction]);

  String commandText;
  NpgsqlConnection? connection;
  NpgsqlTransaction? transaction;
  final NpgsqlParameterCollection parameters = NpgsqlParameterCollection();

  Future<NpgsqlDataReader> executeReader() async {
    if (connection == null || connection!.state != ConnectionState.open) {
      throw StateError('Connection must be open');
    }

    // Delegate to Connection/Connector
    // In strict port this involves sending the query message and creating a UpdateRowDescription
    // For now we will implement a simplified flow

    return connection!.executeReader(commandText, parameters: parameters);
  }

  Future<int> executeNonQuery() async {
    final reader = await executeReader();
    int rows = 0;
    try {
      while (await reader.read()) {
        // Drain rows
      }
      rows = reader.recordsAffected;
    } finally {
      await reader.close();
    }
    return rows;
  }
}
