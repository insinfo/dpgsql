import 'dart:async';
import 'npgsql_batch.dart';
import 'npgsql_notification_event_args.dart';
import 'npgsql_binary_exporter.dart';
import 'npgsql_binary_importer.dart';
import 'npgsql_command.dart';
import 'npgsql_data_reader.dart';
import 'npgsql_parameter_collection.dart';
import 'npgsql_transaction.dart';
import 'npgsql_connection_string_builder.dart';
import 'isolation_level.dart';
import 'internal/npgsql_connector.dart';
import 'protocol/backend_messages.dart';

enum ConnectionState { closed, open, connecting, executing, fetching }

/// Represents an open connection to a PostgreSQL database.
/// Porting NpgsqlConnection.cs
class NpgsqlConnection {
  NpgsqlConnection(this.connectionString) : _returnToPoolAction = null;

  final String connectionString;
  NpgsqlConnector? _connector;
  ConnectionState _state = ConnectionState.closed;

  ConnectionState get state => _state;

  /// Creates and returns a NpgsqlCommand object associated with the current connection.
  NpgsqlCommand createCommand(String commandText) {
    return NpgsqlCommand(commandText, this);
  }

  NpgsqlConnection.fromConnector(this._connector, this._returnToPoolAction)
      : connectionString = '',
        _state = ConnectionState.open;

  final void Function(NpgsqlConnector)? _returnToPoolAction;

  Stream<NpgsqlNotificationEventArgs> get notifications =>
      _notificationController.stream;
  final _notificationController =
      StreamController<NpgsqlNotificationEventArgs>.broadcast();

  Stream<ErrorOrNoticeMessage> get notices => _noticeController.stream;
  final _noticeController = StreamController<ErrorOrNoticeMessage>.broadcast();

  /// Opens a database connection with the property settings specified by the ConnectionString.
  Future<void> open() async {
    if (_state != ConnectionState.closed) {
      throw StateError('Connection already open or connecting');
    }

    _state = ConnectionState.connecting;

    try {
      final builder = NpgsqlConnectionStringBuilder(connectionString);

      _connector = NpgsqlConnector(
        host: builder.host,
        port: builder.port,
        username: builder.username,
        password: builder.password,
        database: builder.database,
        sslMode: builder.sslMode,
        trustServerCertificate: builder.trustServerCertificate,
        encoding: builder.encoding,
      );

      _connector!.notifications.listen((e) {
        _notificationController.add(e);
      });
      _connector!.notices.listen((e) {
        _noticeController.add(e);
      });

      await _connector!.open();
      _state = ConnectionState.open;
    } catch (e) {
      _state = ConnectionState.closed;
      _connector = null;
      rethrow;
    }
  }

  /// Closes the connection to the database.
  Future<void> close() async {
    if (_connector != null) {
      if (_returnToPoolAction != null) {
        _returnToPoolAction(_connector!);
      } else {
        await _connector!.close();
      }
      _connector = null;
    }
    _state = ConnectionState.closed;
  }

  /// Cancels the execution of the current command.
  Future<void> cancel() async {
    if (_connector == null) return;
    await _connector!.cancelRequest();
  }

  /// Begins a database transaction.
  Future<NpgsqlTransaction> beginTransaction(
      [IsolationLevel isolationLevel = IsolationLevel.readCommitted]) async {
    if (_connector == null) throw StateError('Connection closed');

    // Start transaction command
    var sql = 'BEGIN';
    if (isolationLevel != IsolationLevel.readCommitted) {
      switch (isolationLevel) {
        case IsolationLevel.readUncommitted:
          sql += ' ISOLATION LEVEL READ UNCOMMITTED';
          break;
        case IsolationLevel.repeatableRead:
          sql += ' ISOLATION LEVEL REPEATABLE READ';
          break;
        case IsolationLevel.serializable:
          sql += ' ISOLATION LEVEL SERIALIZABLE';
          break;
        case IsolationLevel.snapshot:
          // Snapshot isolation is usually REPEATABLE READ in PG, but explicit snapshot support exists?
          // PG doesn't have "ISOLATION LEVEL SNAPSHOT". It has "REPEATABLE READ" which is snapshot isolation.
          // But Npgsql maps Snapshot to RepeatableRead usually?
          // Or maybe "BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ"
          // Let's stick to standard PG levels.
          sql += ' ISOLATION LEVEL REPEATABLE READ';
          break;
        default:
          break;
      }
    }

    final reader = await executeReader(sql);
    await reader.close();

    return NpgsqlTransaction(this, isolationLevel);
  }

  Future<NpgsqlDataReader> executeReader(String commandText,
      {NpgsqlParameterCollection? parameters, String? statementName}) async {
    if (_connector == null) {
      throw StateError('Connection closed');
    }
    return _connector!.executeReader(commandText,
        parameters: parameters, statementName: statementName);
  }

  Future<void> prepare(String commandText, String statementName,
      NpgsqlParameterCollection parameters) async {
    if (_connector == null) throw StateError('Connection closed');

    // Rewrite SQL to handle ? or @param -> $n
    // Note: This changes parameter usage to be positional index based internally for the prepared statement
    // But parameters collection passed here is used for types?
    // This method seems to assume preparing *before* execution, so types are known?
    // SqlRewriter usage here might be complex because we need to know WHICH params map to $1, $2.
    // NpgsqlCommand handles this by storing the mapping.
    // If we just prepare here, we lose the mapping unless we return it?
    // NpgsqlConnector.prepare probably just needs the SQL and Types.
    // If we rewrite, we get new SQL and Ordered Params.
    // We should pass the Ordered Params to connector.prepare so it sends the correct Type OIDs.

    // However, if we don't return the mapping/rewritten SQL to the caller of this method,
    // they won't know that "SELECT ?" became "SELECT $1" and that $1 corresponds to the first parameter.
    // This method `prepare` on Connection seems insufficient for `?` support if it doesn't return info.
    // It's likely intended for low-level usage where SQL is already valid or NpgsqlCommand calls it.
    // But wait, NpgsqlCommand calls `connection!.prepare(_rewrittenSql!, ...)` in step 106.
    // So NpgsqlCommand ALREADY rewrites.
    // Thus `NpgsqlConnection.prepare` receives ALREADY REWRITTEN SQL if called from NpgsqlCommand.
    // So if the user calls `NpgsqlConnection.prepare` directly with `?`, it might fail unless we rewrite.
    // But if we rewrite, we must return the new SQL/Mapping.
    // Since the signature returns `Future<void>`, we CANNOT return the mapping.
    // checks:
    // IF commandText contains '?', we fail? Or we assume it's raw?
    // Let's leave it as raw. The User should use NpgsqlCommand for smart parameter handling.

    await _connector!.prepare(commandText, statementName, parameters);
  }

  /// Starts a binary COPY FROM STDIN operation.
  Future<NpgsqlBinaryImporter> beginBinaryImport(String copyFromCommand) async {
    if (_connector == null) throw StateError('Connection closed');
    final importer = NpgsqlBinaryImporter(_connector!, copyFromCommand);
    await importer.init();
    return importer;
  }

  /// Starts a binary COPY TO STDOUT operation.
  Future<NpgsqlBinaryExporter> beginBinaryExport(String copyToCommand) async {
    if (_connector == null) throw StateError('Connection closed');
    final exporter = NpgsqlBinaryExporter(_connector!, copyToCommand);
    await exporter.init();
    return exporter;
  }

  NpgsqlBatch createBatch() {
    return NpgsqlBatch(this);
  }

  Future<NpgsqlDataReader> executeBatch(NpgsqlBatch batch) {
    if (_state != ConnectionState.open) {
      throw StateError('Connection is not open');
    }
    // We need to implement executeBatch in NpgsqlConnector
    return _connector!.executeBatch(batch);
  }

  // Pipeline Mode API

  /// Enters pipeline mode, allowing multiple commands to be sent without waiting for responses.
  /// This is a low-level API for advanced scenarios. Most users should use createBatch() instead.
  void enterPipelineMode() {
    if (_state != ConnectionState.open) {
      throw StateError('Connection is not open');
    }
    _connector!.enterPipelineMode();
  }

  /// Exits pipeline mode. All pending commands must be completed before calling this.
  void exitPipelineMode() {
    if (_connector == null) {
      throw StateError('Connection is closed');
    }
    _connector!.exitPipelineMode();
  }

  /// Sends a Sync message, which acts as a barrier in pipeline mode.
  /// All commands sent before this will be executed before any commands sent after.
  Future<void> pipelineSync() async {
    if (_connector == null) {
      throw StateError('Connection is closed');
    }
    await _connector!.pipelineSync();
  }

  /// Whether the connection is currently in pipeline mode.
  bool get inPipelineMode => _connector?.inPipelineMode ?? false;

  /// Execute a query with optional parameter substitution.
  /// Supports different placeholder styles: ?, @param, or $1.
  ///
  /// Example with question marks (PDO style):
  /// ```dart
  /// final results = await conn.query(
  ///   'SELECT * FROM users WHERE id = ? AND name = ?',
  ///   substitutionValues: [42, 'Alice'],
  /// );
  /// ```
  ///
  /// Example with named parameters:
  /// ```dart
  /// final results = await conn.query(
  ///   'SELECT * FROM users WHERE id = @id AND name = @name',
  ///   substitutionValues: {'id': 42, 'name': 'Alice'},
  /// );
  /// ```
  Future<NpgsqlDataReader> query(
    String sql, {
    Object? substitutionValues,
  }) async {
    if (_state != ConnectionState.open) {
      throw StateError('Connection is not open');
    }

    final cmd = createCommand(sql);

    if (substitutionValues != null) {
      if (substitutionValues is List) {
        // Positional parameters (?)
        for (var i = 0; i < substitutionValues.length; i++) {
          cmd.parameters.addWithValue('p$i', substitutionValues[i]);
        }
      } else if (substitutionValues is Map<String, dynamic>) {
        // Named parameters (@name)
        substitutionValues.forEach((name, value) {
          cmd.parameters.addWithValue(name, value);
        });
      } else {
        throw ArgumentError(
          'substitutionValues must be List or Map<String, dynamic>',
        );
      }
    }

    return await cmd.executeReader();
  }

  /// Execute multiple commands efficiently using pipeline mode.
  /// This is a convenience wrapper that enters/exits pipeline automatically.
  Future<void> executeBatchPipelined(List<String> sqlCommands) async {
    if (_state != ConnectionState.open) {
      throw StateError('Connection is not open');
    }

    enterPipelineMode();
    try {
      for (final sql in sqlCommands) {
        await _connector!.executeQueryPipelined(sql: sql);
      }
      await pipelineSync();
    } finally {
      exitPipelineMode();
    }
  }
}
