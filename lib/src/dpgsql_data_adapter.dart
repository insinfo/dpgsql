import 'dart:async';

import 'dpgsql_command.dart';
import 'dpgsql_connection.dart';

typedef DpgsqlRowUpdatedEventHandler = void Function(
  DpgsqlDataAdapter sender,
  DpgsqlRowUpdatedEventArgs args,
);

typedef DpgsqlRowUpdatingEventHandler = void Function(
  DpgsqlDataAdapter sender,
  DpgsqlRowUpdatingEventArgs args,
);

/// Adapter around select/insert/update/delete commands.
///
/// Porting surface for NpgsqlDataAdapter. In Dart this fills lists of maps
/// instead of ADO.NET DataSet/DataTable instances.
class DpgsqlDataAdapter {
  DpgsqlDataAdapter([this.selectCommand]);

  DpgsqlDataAdapter.fromCommandText(
    String selectCommandText,
    DpgsqlConnection selectConnection,
  ) : selectCommand = DpgsqlCommand(selectCommandText, selectConnection);

  DpgsqlDataAdapter.fromConnectionString(
    String selectCommandText,
    String selectConnectionString,
  ) : selectCommand = DpgsqlCommand(
          selectCommandText,
          DpgsqlConnection(selectConnectionString),
        );

  DpgsqlCommand? selectCommand;
  DpgsqlCommand? insertCommand;
  DpgsqlCommand? updateCommand;
  DpgsqlCommand? deleteCommand;

  DpgsqlRowUpdatedEventHandler? rowUpdated;
  DpgsqlRowUpdatingEventHandler? rowUpdating;

  Future<List<Map<String, dynamic>>> fill([
    List<Map<String, dynamic>>? target,
  ]) async {
    final command = selectCommand;
    if (command == null) {
      throw StateError('SelectCommand is required.');
    }

    final connection = command.connection;
    final shouldClose = connection != null &&
        connection.state == ConnectionState.closed &&
        command.connection!.connectionString.isNotEmpty;

    if (shouldClose) {
      await connection.open();
    }

    try {
      final rows = await command.executeMaps();
      if (target != null) {
        target.addAll(rows);
        return target;
      }
      return rows;
    } finally {
      if (shouldClose) {
        await connection.close();
      }
    }
  }

  void onRowUpdating(DpgsqlRowUpdatingEventArgs args) {
    rowUpdating?.call(this, args);
  }

  void onRowUpdated(DpgsqlRowUpdatedEventArgs args) {
    rowUpdated?.call(this, args);
  }
}

class DpgsqlRowUpdatingEventArgs {
  DpgsqlRowUpdatingEventArgs({
    this.command,
    this.statementType,
    this.row,
  });

  final DpgsqlCommand? command;
  final DpgsqlStatementType? statementType;
  final Map<String, dynamic>? row;
}

class DpgsqlRowUpdatedEventArgs {
  DpgsqlRowUpdatedEventArgs({
    this.command,
    this.statementType,
    this.row,
    this.recordsAffected = 0,
  });

  final DpgsqlCommand? command;
  final DpgsqlStatementType? statementType;
  final Map<String, dynamic>? row;
  final int recordsAffected;
}

enum DpgsqlStatementType {
  select,
  insert,
  update,
  delete,
  batch,
}
