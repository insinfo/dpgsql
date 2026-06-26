import 'dart:async';

import 'internal/sql_rewriter.dart';
import 'dpgsql_connection.dart';
import 'dpgsql_data_reader.dart';
import 'dpgsql_parameter_collection.dart';
import 'dpgsql_transaction.dart';
import 'data/pg_row.dart';
import 'pg_result_mode.dart';

/// Represents a SQL statement or function (stored procedure) to execute against a PostgreSQL database.
/// Porting DpgsqlCommand.cs
class DpgsqlCommand {
  DpgsqlCommand([this.commandText = '', this.connection, this.transaction]);

  String commandText;
  DpgsqlConnection? connection;
  DpgsqlTransaction? transaction;
  final DpgsqlParameterCollection parameters = DpgsqlParameterCollection();

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

    // Actually, DpgsqlCommand should hold the state of "Effective SQL" and "Effective Parameters"
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
    final prepParams = DpgsqlParameterCollection();
    prepParams.addAll(rewritten.orderedParameters);
    _preparedOrderedParameters = prepParams;

    await connection!.prepare(_rewrittenSql!, _statementName, prepParams);
    _isPrepared = true;
  }

  String? _rewrittenSql;
  List<String>? _orderedParameterNames;
  DpgsqlParameterCollection? _preparedOrderedParameters;
  String? _cachedUnpreparedSql;
  String? _cachedUnpreparedCommandText;
  List<String>? _cachedUnpreparedParameterNames;
  List<int>? _cachedUnpreparedParameterIdentities;
  DpgsqlParameterCollection? _cachedUnpreparedParameters;

  Future<DpgsqlDataReader> executeReader({
    PgResultMode resultMode = PgResultMode.typed,
  }) async {
    if (connection == null || connection!.state != ConnectionState.open) {
      throw StateError('Connection must be open');
    }

    final plan = buildExecutionPlan();

    if (connection!.inPipelineMode) {
      final pending = await connection!.executeQueryPipelined(
        plan.sql,
        statementName: plan.statementName,
        parameters: plan.parameters,
        resultMode: resultMode,
      );
      return connection!.getPipelineReader(pending);
    }

    return connection!.executeReader(
      plan.sql,
      parameters: plan.parameters,
      statementName: plan.statementName,
      rewriteParameters: plan.rewriteParameters,
      resultMode: resultMode,
    );
  }

  Future<List<List<Object?>>> executeRows() async {
    if (connection == null || connection!.state != ConnectionState.open) {
      throw StateError('Connection must be open');
    }
    if (connection!.inPipelineMode) {
      throw StateError('executeRows cannot be used while in pipeline mode');
    }

    final plan = buildExecutionPlan();
    return connection!.executeRows(
      plan.sql,
      parameters: plan.parameters,
      statementName: plan.statementName,
      rewriteParameters: plan.rewriteParameters,
    );
  }

  Future<List<Map<String, dynamic>>> executeMaps({
    PgResultMode resultMode = PgResultMode.typed,
  }) async {
    if (connection == null || connection!.state != ConnectionState.open) {
      throw StateError('Connection must be open');
    }
    if (connection!.inPipelineMode) {
      throw StateError('executeMaps cannot be used while in pipeline mode');
    }

    final plan = buildExecutionPlan();
    return connection!.executeMaps(
      plan.sql,
      parameters: plan.parameters,
      statementName: plan.statementName,
      rewriteParameters: plan.rewriteParameters,
      resultMode: resultMode,
    );
  }

  Future<List<PgRow>> executePgRows() async {
    if (connection == null || connection!.state != ConnectionState.open) {
      throw StateError('Connection must be open');
    }
    if (connection!.inPipelineMode) {
      throw StateError('executePgRows cannot be used while in pipeline mode');
    }

    final plan = buildExecutionPlan();
    return connection!.executePgRows(
      plan.sql,
      parameters: plan.parameters,
      statementName: plan.statementName,
      rewriteParameters: plan.rewriteParameters,
    );
  }

  Future<void> forEachPgRow(FutureOr<void> Function(PgRow row) action) async {
    if (connection == null || connection!.state != ConnectionState.open) {
      throw StateError('Connection must be open');
    }
    if (connection!.inPipelineMode) {
      throw StateError('forEachPgRow cannot be used while in pipeline mode');
    }

    final plan = buildExecutionPlan();
    return connection!.forEachPgRow(
      plan.sql,
      action,
      parameters: plan.parameters,
      statementName: plan.statementName,
      rewriteParameters: plan.rewriteParameters,
    );
  }

  Future<void> forEachPgRowSync(void Function(PgRow row) action) async {
    if (connection == null || connection!.state != ConnectionState.open) {
      throw StateError('Connection must be open');
    }
    if (connection!.inPipelineMode) {
      throw StateError(
          'forEachPgRowSync cannot be used while in pipeline mode');
    }

    final plan = buildExecutionPlan();
    return connection!.forEachPgRowSync(
      plan.sql,
      action,
      parameters: plan.parameters,
      statementName: plan.statementName,
      rewriteParameters: plan.rewriteParameters,
    );
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

  /// Builds the execution plan for this command (internal use).
  /// Returns the SQL text to send, the ordered parameters (if any),
  /// and the prepared statement name when applicable.
  DpgsqlCommandExecutionPlan buildExecutionPlan() {
    String sqlToExecute = commandText;
    DpgsqlParameterCollection? paramsToUse;
    String? statementName;

    if (_isPrepared) {
      statementName = _statementName;
      sqlToExecute = _rewrittenSql ?? commandText;

      if (_preparedOrderedParameters != null) {
        paramsToUse = _preparedOrderedParameters;
      } else if (_orderedParameterNames != null &&
          _orderedParameterNames!.isNotEmpty) {
        final orderedParams = DpgsqlParameterCollection();
        for (final name in _orderedParameterNames!) {
          final param = parameters.firstWhere(
            (p) => p.parameterName == name,
            orElse: () => throw StateError(
                'Parameter @$name not found during prepared execution'),
          );
          orderedParams.add(param);
        }
        paramsToUse = orderedParams;
      } else if (parameters.isNotEmpty) {
        paramsToUse = DpgsqlParameterCollection()..addAll(parameters);
      }
    } else if (parameters.isNotEmpty) {
      if (!_canReuseCachedUnpreparedPlan()) {
        final rewritten = SqlRewriter.rewrite(commandText, parameters);
        final orderedParams = DpgsqlParameterCollection();
        orderedParams.addAll(rewritten.orderedParameters);
        _cachedUnpreparedSql = rewritten.sql;
        _cachedUnpreparedParameters = orderedParams;
        _cacheUnpreparedPlanShape();
      }
      sqlToExecute = _cachedUnpreparedSql!;
      paramsToUse = _cachedUnpreparedParameters;
    }

    return DpgsqlCommandExecutionPlan(
      sql: sqlToExecute,
      parameters: paramsToUse,
      statementName: statementName,
      rewriteParameters: false,
    );
  }

  bool _canReuseCachedUnpreparedPlan() {
    if (_cachedUnpreparedSql == null ||
        _cachedUnpreparedParameters == null ||
        _cachedUnpreparedCommandText != commandText) {
      return false;
    }

    final names = _cachedUnpreparedParameterNames;
    final identities = _cachedUnpreparedParameterIdentities;
    if (names == null ||
        identities == null ||
        names.length != parameters.length ||
        identities.length != parameters.length) {
      return false;
    }

    for (var i = 0; i < parameters.length; i++) {
      final parameter = parameters[i];
      if (names[i] != parameter.parameterName ||
          identities[i] != identityHashCode(parameter)) {
        return false;
      }
    }
    return true;
  }

  void _cacheUnpreparedPlanShape() {
    _cachedUnpreparedCommandText = commandText;
    _cachedUnpreparedParameterNames = List<String>.generate(
      parameters.length,
      (i) => parameters[i].parameterName,
      growable: false,
    );
    _cachedUnpreparedParameterIdentities = List<int>.generate(
      parameters.length,
      (i) => identityHashCode(parameters[i]),
      growable: false,
    );
  }
}

/// Internal representation of an DpgsqlCommand execution plan.
class DpgsqlCommandExecutionPlan {
  DpgsqlCommandExecutionPlan({
    required this.sql,
    this.parameters,
    this.statementName,
    this.rewriteParameters = true,
  });

  final String sql;
  final DpgsqlParameterCollection? parameters;
  final String? statementName;
  final bool rewriteParameters;

  bool get hasParameters => parameters != null && parameters!.isNotEmpty;
}
