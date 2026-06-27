import 'dart:async';
import 'dpgsql_batch.dart';
import 'dpgsql_notification_event_args.dart';
import 'dpgsql_binary_exporter.dart';
import 'dpgsql_binary_importer.dart';
import 'dpgsql_command.dart';
import 'dpgsql_data_reader.dart';
import 'dpgsql_parameter_collection.dart';
import 'dpgsql_raw_copy_stream.dart';
import 'dpgsql_transaction.dart';
import 'dpgsql_connection_string_builder.dart';
import 'data/pg_row.dart';
import 'isolation_level.dart';
import 'internal/dpgsql_connector.dart';
import 'protocol/backend_messages.dart';
import 'internal/pending_command.dart';
import 'pg_result_mode.dart';

enum ConnectionState { closed, open, connecting, executing, fetching }

/// Represents an open connection to a PostgreSQL database.
/// Porting DpgsqlConnection.cs
class DpgsqlConnection {
  DpgsqlConnection(this.connectionString) : _returnToPoolAction = null;

  final String connectionString;
  DpgsqlConnector? _connector;
  ConnectionState _state = ConnectionState.closed;
  int _activeReaderCount = 0;
  bool _activeTransaction = false;
  bool _activeCopyOperation = false;
  bool _discardConnectorOnClose = false;

  ConnectionState get state => _state;
  bool get hasActiveReader => _activeReaderCount > 0;
  bool get hasActiveTransaction => _activeTransaction;
  bool get hasActiveCopyOperation => _activeCopyOperation;
  bool get isSafeToReturnToPool =>
      !_discardConnectorOnClose &&
      !hasActiveReader &&
      !hasActiveTransaction &&
      !hasActiveCopyOperation &&
      !inPipelineMode;

  /// Marks the physical connector as unsafe for pool reuse.
  ///
  /// Use this after network/protocol failures where the backend state is not
  /// guaranteed to be synchronized anymore.
  void markUnusable() {
    _discardConnectorOnClose = true;
  }

  /// Creates and returns a DpgsqlCommand object associated with the current connection.
  DpgsqlCommand createCommand(String commandText) {
    return DpgsqlCommand(commandText, this);
  }

  DpgsqlConnection.fromConnector(this._connector, this._returnToPoolAction)
      : connectionString = '',
        _state = ConnectionState.open;

  final void Function(DpgsqlConnector)? _returnToPoolAction;

  Stream<DpgsqlNotificationEventArgs> get notifications =>
      _notificationController.stream;
  final _notificationController =
      StreamController<DpgsqlNotificationEventArgs>.broadcast();

  Stream<ErrorOrNoticeMessage> get notices => _noticeController.stream;
  final _noticeController = StreamController<ErrorOrNoticeMessage>.broadcast();

  /// Opens a database connection with the property settings specified by the ConnectionString.
  Future<void> open() async {
    if (_state != ConnectionState.closed) {
      throw StateError('Connection already open or connecting');
    }

    _state = ConnectionState.connecting;

    try {
      final builder = DpgsqlConnectionStringBuilder(connectionString);

      _connector = DpgsqlConnector(
        host: builder.host,
        port: builder.port,
        username: builder.username,
        password: builder.password,
        database: builder.database,
        sslMode: builder.sslMode,
        trustServerCertificate: builder.trustServerCertificate,
        encoding: builder.encoding,
        clientEncoding: builder.postgresClientEncoding,
        timeZone: builder.timeZone,
        maxAutoPrepare: builder.maxAutoPrepare,
        autoPrepareMinUsages: builder.autoPrepareMinUsages,
        decodeNetworkTypesAsString: builder.decodeNetworkTypesAsString,
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
      final connector = _connector!;
      if (_returnToPoolAction != null) {
        if (!isSafeToReturnToPool) {
          await connector.close();
        }
        _returnToPoolAction(connector);
      } else {
        await connector.close();
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
  Future<DpgsqlTransaction> beginTransaction(
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
          // But Dpgsql maps Snapshot to RepeatableRead usually?
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

    _activeTransaction = true;
    return DpgsqlTransaction(
      this,
      isolationLevel,
      onCompleted: () {
        _activeTransaction = false;
      },
    );
  }

  Future<DpgsqlDataReader> executeReader(String commandText,
      {DpgsqlParameterCollection? parameters,
      String? statementName,
      bool rewriteParameters = true,
      PgResultMode resultMode = PgResultMode.typed}) async {
    if (_connector == null) {
      throw StateError('Connection closed');
    }
    final reader = await _connector!.executeReader(commandText,
        parameters: parameters,
        statementName: statementName,
        rewriteParameters: rewriteParameters,
        resultMode: resultMode);
    return _trackReader(reader);
  }

  Future<List<List<Object?>>> executeRows(
    String commandText, {
    DpgsqlParameterCollection? parameters,
    String? statementName,
    bool rewriteParameters = true,
  }) {
    if (_connector == null) {
      throw StateError('Connection closed');
    }
    return _connector!.executeRows(
      commandText,
      parameters: parameters,
      statementName: statementName,
      rewriteParameters: rewriteParameters,
    );
  }

  Future<Object?> executeScalar(
    String commandText, {
    DpgsqlParameterCollection? parameters,
    String? statementName,
    bool rewriteParameters = true,
  }) {
    if (_connector == null) {
      throw StateError('Connection closed');
    }
    return _connector!.executeScalar(
      commandText,
      parameters: parameters,
      statementName: statementName,
      rewriteParameters: rewriteParameters,
    );
  }

  Future<List<Map<String, dynamic>>> executeMaps(
    String commandText, {
    DpgsqlParameterCollection? parameters,
    String? statementName,
    bool rewriteParameters = true,
    PgResultMode resultMode = PgResultMode.typed,
  }) {
    if (_connector == null) {
      throw StateError('Connection closed');
    }
    return _connector!.executeMaps(
      commandText,
      parameters: parameters,
      statementName: statementName,
      rewriteParameters: rewriteParameters,
      resultMode: resultMode,
    );
  }

  Future<List<PgRow>> executePgRows(
    String commandText, {
    DpgsqlParameterCollection? parameters,
    String? statementName,
    bool rewriteParameters = true,
  }) {
    if (_connector == null) {
      throw StateError('Connection closed');
    }
    return _connector!.executePgRows(
      commandText,
      parameters: parameters,
      statementName: statementName,
      rewriteParameters: rewriteParameters,
    );
  }

  Future<void> forEachPgRow(
    String commandText,
    FutureOr<void> Function(PgRow row) action, {
    DpgsqlParameterCollection? parameters,
    String? statementName,
    bool rewriteParameters = true,
  }) {
    if (_connector == null) {
      throw StateError('Connection closed');
    }
    return _connector!.forEachPgRow(
      commandText,
      action,
      parameters: parameters,
      statementName: statementName,
      rewriteParameters: rewriteParameters,
    );
  }

  Future<void> forEachPgRowSync(
    String commandText,
    void Function(PgRow row) action, {
    DpgsqlParameterCollection? parameters,
    String? statementName,
    bool rewriteParameters = true,
  }) {
    if (_connector == null) {
      throw StateError('Connection closed');
    }
    return _connector!.forEachPgRowSync(
      commandText,
      action,
      parameters: parameters,
      statementName: statementName,
      rewriteParameters: rewriteParameters,
    );
  }

  Future<void> prepare(String commandText, String statementName,
      DpgsqlParameterCollection parameters) async {
    if (_connector == null) throw StateError('Connection closed');

    // Rewrite SQL to handle ? or @param -> $n
    // Note: This changes parameter usage to be positional index based internally for the prepared statement
    // But parameters collection passed here is used for types?
    // This method seems to assume preparing *before* execution, so types are known?
    // SqlRewriter usage here might be complex because we need to know WHICH params map to $1, $2.
    // DpgsqlCommand handles this by storing the mapping.
    // If we just prepare here, we lose the mapping unless we return it?
    // DpgsqlConnector.prepare probably just needs the SQL and Types.
    // If we rewrite, we get new SQL and Ordered Params.
    // We should pass the Ordered Params to connector.prepare so it sends the correct Type OIDs.

    // However, if we don't return the mapping/rewritten SQL to the caller of this method,
    // they won't know that "SELECT ?" became "SELECT $1" and that $1 corresponds to the first parameter.
    // This method `prepare` on Connection seems insufficient for `?` support if it doesn't return info.
    // It's likely intended for low-level usage where SQL is already valid or DpgsqlCommand calls it.
    // But wait, DpgsqlCommand calls `connection!.prepare(_rewrittenSql!, ...)` in step 106.
    // So DpgsqlCommand ALREADY rewrites.
    // Thus `DpgsqlConnection.prepare` receives ALREADY REWRITTEN SQL if called from DpgsqlCommand.
    // So if the user calls `DpgsqlConnection.prepare` directly with `?`, it might fail unless we rewrite.
    // But if we rewrite, we must return the new SQL/Mapping.
    // Since the signature returns `Future<void>`, we CANNOT return the mapping.
    // checks:
    // IF commandText contains '?', we fail? Or we assume it's raw?
    // Let's leave it as raw. The User should use DpgsqlCommand for smart parameter handling.

    await _connector!.prepare(commandText, statementName, parameters);
  }

  /// Starts a binary COPY FROM STDIN operation.
  Future<DpgsqlBinaryImporter> beginBinaryImport(String copyFromCommand) async {
    if (_connector == null) throw StateError('Connection closed');
    _activeCopyOperation = true;
    try {
      final importer = DpgsqlBinaryImporter(
        _connector!,
        copyFromCommand,
        _handleCopyOperationClosed,
      );
      await importer.init();
      return importer;
    } catch (_) {
      _activeCopyOperation = false;
      _discardConnectorOnClose = true;
      rethrow;
    }
  }

  /// Starts a binary COPY TO STDOUT operation.
  Future<DpgsqlBinaryExporter> beginBinaryExport(String copyToCommand) async {
    if (_connector == null) throw StateError('Connection closed');
    _activeCopyOperation = true;
    try {
      final exporter = DpgsqlBinaryExporter(
        _connector!,
        copyToCommand,
        _handleCopyOperationClosed,
      );
      await exporter.init();
      return exporter;
    } catch (_) {
      _activeCopyOperation = false;
      _discardConnectorOnClose = true;
      rethrow;
    }
  }

  /// Starts a raw COPY operation.
  ///
  /// The returned stream works with COPY FROM STDIN and COPY TO STDOUT in
  /// binary, text, or CSV format. Unlike [beginBinaryImport] and
  /// [beginBinaryExport], no row/value encoding is performed by the driver.
  Future<DpgsqlRawCopyStream> beginRawBinaryCopy(
    String copyCommand, {
    DpgsqlCopyProgressCallback? onProgress,
  }) async {
    if (_connector == null) throw StateError('Connection closed');
    _activeCopyOperation = true;
    try {
      final stream = DpgsqlRawCopyStream(
        _connector!,
        copyCommand,
        _handleCopyOperationClosed,
        onProgress,
      );
      await stream.init();
      return stream;
    } catch (_) {
      _activeCopyOperation = false;
      _discardConnectorOnClose = true;
      rethrow;
    }
  }

  /// Starts a textual COPY FROM STDIN operation.
  Future<DpgsqlRawCopyStream> beginTextImport(
    String copyFromCommand, {
    DpgsqlCopyProgressCallback? onProgress,
  }) {
    return beginRawBinaryCopy(copyFromCommand, onProgress: onProgress);
  }

  /// Starts a textual COPY TO STDOUT operation.
  Future<DpgsqlRawCopyStream> beginTextExport(
    String copyToCommand, {
    DpgsqlCopyProgressCallback? onProgress,
  }) {
    return beginRawBinaryCopy(copyToCommand, onProgress: onProgress);
  }

  DpgsqlBatch createBatch() {
    return DpgsqlBatch(this);
  }

  Future<DpgsqlDataReader> executeBatch(DpgsqlBatch batch) async {
    if (_state != ConnectionState.open) {
      throw StateError('Connection is not open');
    }
    // We need to implement executeBatch in DpgsqlConnector
    final reader = await _connector!.executeBatch(batch);
    return _trackReader(reader);
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

  /// Flushes the write buffer without sending Sync, allowing the server to
  /// start processing commands that have already been queued.
  Future<void> flushPipeline() async {
    if (_connector == null) {
      throw StateError('Connection is closed');
    }
    await _connector!.flushPipeline();
  }

  /// Whether the connection is currently in pipeline mode.
  bool get inPipelineMode => _connector?.inPipelineMode ?? false;

  /// Sends a query while in pipeline mode, returning a handle that can be used
  /// to consume the results once available.
  Future<PendingCommand> executeQueryPipelined(
    String sql, {
    DpgsqlParameterCollection? parameters,
    String? statementName,
    PgResultMode resultMode = PgResultMode.typed,
  }) async {
    if (_state != ConnectionState.open) {
      throw StateError('Connection is not open');
    }
    if (_connector == null) {
      throw StateError('Connection is closed');
    }
    return _connector!.executeQueryPipelined(
      sql: sql,
      statementName: statementName,
      parameters: parameters,
      resultMode: resultMode,
    );
  }

  /// Creates a data reader that streams the results of a pending pipeline command.
  Future<DpgsqlDataReader> getPipelineReader(PendingCommand command) async {
    if (_connector == null) {
      throw StateError('Connection is closed');
    }
    final reader = await _connector!.createPipelineReaderForCommand(command);
    return _trackReader(reader);
  }

  /// Creates a reader that will iterate over multiple pending commands in order.
  Future<DpgsqlDataReader> getPipelineReaderForCommands(
      List<PendingCommand> commands) async {
    if (_connector == null) {
      throw StateError('Connection is closed');
    }
    final reader = await _connector!.createPipelineReader(commands);
    return _trackReader(reader);
  }

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
  Future<DpgsqlDataReader> query(
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

  /// Executes multiple [DpgsqlCommand] instances using pipeline mode, returning
  /// a single reader that iterates over all results in order.
  /// When [autoEnterPipeline] is true (default), the connection enters pipeline
  /// mode automatically and schedules an automatic exit after the next
  /// ReadyForQuery.
  Future<DpgsqlDataReader> executeCommandsPipelined(
    List<DpgsqlCommand> commands, {
    bool autoEnterPipeline = true,
  }) async {
    if (commands.isEmpty) {
      throw ArgumentError('commands cannot be empty');
    }
    if (_state != ConnectionState.open) {
      throw StateError('Connection is not open');
    }
    if (_connector == null) {
      throw StateError('Connection is closed');
    }

    final wasInPipeline = inPipelineMode;
    if (!wasInPipeline) {
      if (!autoEnterPipeline) {
        throw StateError(
            'Connection is not in pipeline mode. Set autoEnterPipeline to true or call enterPipelineMode() manually.');
      }
      enterPipelineMode();
    }

    final pendingCommands = <PendingCommand>[];

    try {
      for (final cmd in commands) {
        if (cmd.connection != null && cmd.connection != this) {
          throw StateError(
              'Command is associated with a different connection instance');
        }
        cmd.connection ??= this;

        final plan = cmd.buildExecutionPlan();
        final pending = await executeQueryPipelined(
          plan.sql,
          parameters: plan.parameters,
          statementName: plan.statementName,
        );
        pendingCommands.add(pending);
      }

      await pipelineSync();
      if (!wasInPipeline) {
        _connector!.scheduleAutoExitPipelineOnReady();
      }
    } catch (e, st) {
      if (!wasInPipeline && inPipelineMode) {
        _connector!.cancelAutoExitPipelineOnReady();
        _connector!.abortPipeline(e, st);
      }
      rethrow;
    }

    final reader = await _connector!
        .createPipelineReader(List.unmodifiable(pendingCommands));
    return _trackReader(reader);
  }

  DpgsqlDataReader _trackReader(DpgsqlDataReader reader) {
    _activeReaderCount++;
    return _TrackedDpgsqlDataReader(reader, () {
      if (_activeReaderCount > 0) {
        _activeReaderCount--;
      }
    });
  }

  void _handleCopyOperationClosed(bool reusable) {
    _activeCopyOperation = false;
    if (!reusable) {
      _discardConnectorOnClose = true;
    }
  }
}

class _TrackedDpgsqlDataReader implements DpgsqlDataReader {
  _TrackedDpgsqlDataReader(this._inner, this._onClosed);

  final DpgsqlDataReader _inner;
  final void Function() _onClosed;
  bool _closed = false;

  @override
  int get fieldCount => _inner.fieldCount;

  @override
  int get recordsAffected => _inner.recordsAffected;

  @override
  dynamic operator [](dynamic index) => _inner[index];

  @override
  dynamic getValue(int ordinal) => _inner.getValue(ordinal);

  @override
  Map<String, dynamic> toMap() => _inner.toMap();

  @override
  Future<List<Map<String, dynamic>>> readAllMaps() => _inner.readAllMaps();

  @override
  bool isDBNull(int ordinal) => _inner.isDBNull(ordinal);

  @override
  int getInt(int ordinal) => _inner.getInt(ordinal);

  @override
  String getString(int ordinal) => _inner.getString(ordinal);

  @override
  double getDouble(int ordinal) => _inner.getDouble(ordinal);

  @override
  bool getBool(int ordinal) => _inner.getBool(ordinal);

  @override
  DateTime getDateTime(int ordinal) => _inner.getDateTime(ordinal);

  @override
  int getOrdinal(String name) => _inner.getOrdinal(name);

  @override
  Future<bool> nextResult() => _inner.nextResult();

  @override
  Future<bool> read() => _inner.read();

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    try {
      await _inner.close();
    } finally {
      _onClosed();
    }
  }
}
