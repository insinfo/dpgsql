import 'dart:async';

import 'internal/sql_rewriter.dart';
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

  bool _isPrepared = false;
  String _statementName = '';

  Future<void> prepare() async {
    if (connection == null || connection!.state != ConnectionState.open) {
      throw StateError('Connection must be open');
    }
    if (_isPrepared) return;

    _statementName = 'prep_${hashCode}';

    // Rewrite SQL
    final rewritten = SqlRewriter.rewrite(commandText, parameters);
    // Note: We should probably store the rewritten SQL and ordered params for execution
    // But for now, let's just pass the rewritten SQL to prepare.
    // Wait, if we rewrite, we change the parameter order.
    // We need to store the mapping or the ordered list for subsequent executions.

    // Actually, NpgsqlCommand should hold the state of "Effective SQL" and "Effective Parameters"
    // For simplicity, let's assume the user doesn't change parameters collection structure after prepare, only values.

    // We need to update the connector to accept the ordered parameters.
    // But wait, parameters collection is mutable.

    // Let's keep it simple:
    // 1. Rewrite
    // 2. Prepare with rewritten SQL and ordered types.

    // But executeReader needs to know how to map current parameters to the prepared statement's $1, $2...

    // We need to store the RewrittenSql result?
    // Or just the ordered list of parameter names?

    _rewrittenSql = rewritten.sql;
    _orderedParameterNames =
        rewritten.orderedParameters.map((p) => p.parameterName).toList();

    // Create a temporary collection for prepare (just for types)
    final prepParams = NpgsqlParameterCollection();
    prepParams.addAll(rewritten.orderedParameters);

    await connection!.prepare(_rewrittenSql!, _statementName, prepParams);
    _isPrepared = true;
  }

  String? _rewrittenSql;
  List<String>? _orderedParameterNames;

  Future<NpgsqlDataReader> executeReader() async {
    if (connection == null || connection!.state != ConnectionState.open) {
      throw StateError('Connection must be open');
    }

    // If not prepared, we still need to rewrite if there are parameters
    String sqlToExecute = commandText;
    NpgsqlParameterCollection paramsToUse = parameters;

    if (_isPrepared) {
      // Use the prepared statement
      // We need to construct the parameter values in the correct order expected by the prepared statement
      final orderedParams = NpgsqlParameterCollection();
      if (_orderedParameterNames != null) {
        for (final name in _orderedParameterNames!) {
          // Find current value in user collection
          final p = parameters.firstWhere((x) => x.parameterName == name);
          orderedParams.add(p);
        }
      }

      return connection!.executeReader(
          sqlToExecute, // Ignored if statementName is present, but good for debug
          parameters: orderedParams,
          statementName: _statementName);
    } else {
      // Not prepared
      if (parameters.isNotEmpty) {
        final rewritten = SqlRewriter.rewrite(commandText, parameters);
        sqlToExecute = rewritten.sql;
        paramsToUse = NpgsqlParameterCollection();
        paramsToUse.addAll(rewritten.orderedParameters);
      }

      return connection!.executeReader(sqlToExecute, parameters: paramsToUse);
    }
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
