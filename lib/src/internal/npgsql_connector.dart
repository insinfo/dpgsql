import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';

import 'package:pointycastle/export.dart' as pc;

import '../io/binary_input.dart';
import '../io/binary_output.dart';
import '../protocol/backend_messages.dart';
import '../protocol/frontend_messages.dart';
import '../protocol/postgres_message.dart';
import '../postgres_exception.dart';
import '../npgsql_data_reader.dart';
import '../npgsql_parameter_collection.dart';
import '../types/type_handler.dart';
import '../npgsql_batch.dart';
import 'npgsql_data_reader_impl.dart';
import 'scram_authenticator.dart';
import 'sql_rewriter.dart';
import 'pipeline_command_queue.dart';
import 'pending_command.dart';
import '../npgsql_notification_event_args.dart';
import '../ssl_mode.dart';

/// Represents a connection to a PostgreSQL backend.
/// Porting NpgsqlConnector.cs
class NpgsqlConnector {
  NpgsqlConnector({
    required this.host,
    this.port = 5432,
    this.username = 'postgres',
    this.password = '',
    this.database = 'postgres',
    this.sslMode = SslMode.disable,
    this.trustServerCertificate = false,
    this.encoding = utf8,
    this.replication = false,
  });

  final String host;
  final int port;
  final String username;
  final String password;
  final String database;
  final SslMode sslMode;
  final bool trustServerCertificate;
  final Encoding encoding;
  final bool replication;

  Socket? _socket;
  SocketBinaryInput? _readBuffer;
  SocketBinaryOutput? _writeBuffer;

  PostgresMessageReader? _msgReader;
  PostgresMessageWriter? _msgWriter;

  final TypeHandlerRegistry _typeRegistry = TypeHandlerRegistry();

  FrontendMessages? _frontendMessages;
  late BackendMessageReader _backendReader;
  ScramSha256Authenticator? _scram;

  bool _isConnected = false;
  bool get isConnected => _isConnected;
  Map<String, String> _serverParameters = {};
  int _backendProcessId = 0;
  int _backendSecretKey = 0;

  TypeHandlerRegistry get typeRegistry => _typeRegistry;

  /// Opens the connection.
  Future<void> open() async {
    if (_isConnected) return;

    try {
      // 1. Connect to Socket
      _socket = await Socket.connect(host, port);
      _socket!.setOption(SocketOption.tcpNoDelay, true);

      Stream<List<int>> inputStream = _socket!;

      // SSL Handshake
      if (sslMode != SslMode.disable) {
        // Use broadcast stream to allow peeking/reading handshake response
        final broadcast = _socket!.asBroadcastStream();
        inputStream = broadcast;

        // Send SSLRequest
        final sslReq = ByteData(8);
        sslReq.setInt32(0, 8);
        sslReq.setInt32(4, 80877103);
        _socket!.add(sslReq.buffer.asUint8List());

        // Read response byte
        final completer = Completer<int>();
        final sub = broadcast.listen(
          (data) {
            if (data.isNotEmpty) {
              completer.complete(data[0]);
            }
          },
          onError: completer.completeError,
          onDone: () => completer.completeError(
              Exception('Connection closed during SSL handshake')),
        );

        final response = await completer.future;
        await sub.cancel(); // Stop listening so we can switch or continue

        if (response == 83) {
          // 'S'
          // Upgrade to SSL
          _socket = await SecureSocket.secure(
            _socket!,
            onBadCertificate: (cert) {
              // If TrustServerCertificate is true, we always trust.
              if (trustServerCertificate) return true;

              // If SslMode is VerifyCA or VerifyFull, we expect strict validation.
              // SecureSocket by default validates against system CAs.
              // If we are here, validation FAILED.

              // If SslMode is Allow or Prefer, we might be lenient?
              // Npgsql docs: "Prefer: ... If SSL is used, the server certificate is validated."
              // So if validation fails, we should reject, unless TrustServerCertificate is true.

              // However, historically 'Allow' might have been loose.
              // But standard Npgsql behavior is: if SSL is negotiated, validation happens unless TrustServerCertificate=true.

              return false;
            },
          );
          // Update inputStream to the new SecureSocket
          inputStream = _socket!;
        } else if (response == 78) {
          // 'N'
          if (sslMode == SslMode.require) {
            throw PostgresException(
              severity: 'FATAL',
              invariantSeverity: 'FATAL',
              sqlState: '08000',
              messageText: 'The server does not support SSL.',
            );
          }
          // Proceed with cleartext using the broadcast stream
        } else {
          throw PostgresException(
            severity: 'FATAL',
            invariantSeverity: 'FATAL',
            sqlState: '08000',
            messageText:
                'Received invalid SSL response from server: ${String.fromCharCode(response)}',
          );
        }
      }

      // 2. Initialize Buffers
      _readBuffer = SocketBinaryInput(inputStream);
      _writeBuffer = SocketBinaryOutput(_socket!);

      // Readers/Writers helpers
      _msgReader = PostgresMessageReader(_readBuffer!);
      _msgWriter = PostgresMessageWriter(
        _writeBuffer!,
        useBuffer: true,
        bufferSize: 16384,
      );
      _frontendMessages = FrontendMessages(_msgWriter!, encoding: encoding);
      _backendReader = BackendMessageReader(_msgReader!);

      // 3. Start Handshake
      await _handleStartup();

      _isConnected = true;
    } catch (e) {
      await close();
      rethrow;
    }
  }

  Future<void> close() async {
    if (_socket != null) {
      try {
        await _frontendMessages?.writeTerminate();
      } catch (_) {
        // Ignore errors during termination
      }
      await _socket!.close();
      _socket = null;
    }
    _isConnected = false;
  }

  Future<void> cancelRequest() async {
    if (_backendProcessId == 0 || _backendSecretKey == 0) return;

    try {
      final socket = await Socket.connect(host, port);
      final buffer = SocketBinaryOutput(socket);
      final writer = PostgresMessageWriter(buffer);
      final frontend = FrontendMessages(writer);

      await frontend.writeCancelRequest(_backendProcessId, _backendSecretKey);
      await socket.flush();
      await socket.close();
    } catch (e) {
      // Ignore errors during cancel
    }
  }

  Future<void> _handleStartup() async {
    // Write Startup Message
    final params = <String, String>{};
    if (replication) {
      params['replication'] = 'database';
    }

    await _frontendMessages!.writeStartupMessage(
      user: username,
      database: database,
      parameters: params,
    );

    // Read response loop
    while (true) {
      final msg = await _readMessage();

      if (msg is ErrorResponseMessage) {
        final err = msg.error;
        throw PostgresException(
            severity: err.severity ?? 'ERROR',
            invariantSeverity: err.invariantSeverity ?? err.severity ?? 'ERROR',
            sqlState: err.sqlState ?? '00000',
            messageText: err.messageText ?? 'Unknown Error',
            detail: err.detail,
            hint: err.hint,
            position: err.position ?? 0,
            internalPosition: err.internalPosition ?? 0,
            internalQuery: err.internalQuery,
            where: err.where,
            schemaName: err.schemaName,
            tableName: err.tableName,
            columnName: err.columnName,
            dataTypeName: err.dataTypeName,
            constraintName: err.constraintName,
            file: err.file,
            line: err.line,
            routine: err.routine);
      }

      if (msg is AuthenticationRequestMessage) {
        await _handleAuthentication(msg);
        continue;
      }

      if (msg is ParameterStatusMessage) {
        _serverParameters[msg.parameter] = msg.value;
        continue;
      }

      if (msg is BackendKeyDataMessage) {
        _backendProcessId = msg.processId;
        _backendSecretKey = msg.secretKey;
        continue;
      }

      if (msg is ReadyForQueryMessage) {
        break; // Handshake complete
      }
    }
  }

  Future<void> _handleAuthentication(AuthenticationRequestMessage msg) async {
    if (msg is AuthenticationOkMessage) {
      return;
    }

    if (msg is AuthenticationMD5PasswordMessage) {
      final hash = _computeMD5(username, password, msg.salt);
      await _frontendMessages!.writePassword(hash);
      return;
    }

    if (msg is AuthenticationCleartextPasswordMessage) {
      await _frontendMessages!.writePassword(password);
      return;
    }

    if (msg is AuthenticationSASLMessage) {
      if (msg.mechanisms.contains('SCRAM-SHA-256')) {
        _scram = ScramSha256Authenticator(username, password);
        final initial = _scram!.createInitialResponse();
        await _frontendMessages!
            .writeSASLInitialResponse('SCRAM-SHA-256', initial);
        return;
      }
      throw UnimplementedError(
          'No supported SASL mechanism found in ${msg.mechanisms}');
    }

    if (msg is AuthenticationSASLContinueMessage) {
      if (_scram == null) throw StateError('SASL Continue without Initial');
      final serverMsg = utf8.decode(msg.payload);
      final response = _scram!.handleContinue(serverMsg);
      await _frontendMessages!.writeSASLResponse(response);
      return;
    }

    if (msg is AuthenticationSASLFinalMessage) {
      if (_scram == null) throw StateError('SASL Final without Initial');
      final serverMsg = utf8.decode(msg.payload);
      _scram!.verifyServerSignature(serverMsg);
      return;
    }

    throw UnimplementedError(
        'Authentication type ${msg.authRequestType} not supported');
  }

  String _computeMD5(String user, String password, Uint8List salt) {
    // MD5(MD5(password + user) + salt)
    final d1 = pc.MD5Digest();
    final step1 = d1.process(utf8.encode(password + user));
    final hex1 = _toHex(step1);

    final d2 = pc.MD5Digest();
    final step2 = d2.process(Uint8List.fromList(utf8.encode(hex1) + salt));
    return 'md5${_toHex(step2)}';
  }

  String _toHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  final _notificationController =
      StreamController<NpgsqlNotificationEventArgs>.broadcast();
  Stream<NpgsqlNotificationEventArgs> get notifications =>
      _notificationController.stream;

  final _noticeController = StreamController<ErrorOrNoticeMessage>.broadcast();
  Stream<ErrorOrNoticeMessage> get notices => _noticeController.stream;

  Future<IBackendMessage> readMessage() async {
    while (true) {
      final msg = await _readRawMessage();

      _processPipelineMessage(msg);

      if (_pipelineDrainingAfterError &&
          !_shouldDeliverWhileDraining(msg)) {
        continue;
      }

      if (msg is NotificationResponseMessage) {
        _notificationController.add(NpgsqlNotificationEventArgs(
            msg.channel, msg.payload, msg.processId));
        continue;
      }
      if (msg is NoticeResponseMessage) {
        _noticeController.add(msg.notice);
        continue;
      }
      if (msg is ParameterStatusMessage) {
        _serverParameters[msg.parameter] = msg.value;
        continue;
      }
      return msg;
    }
  }

  bool _shouldDeliverWhileDraining(IBackendMessage msg) {
    if (msg is ReadyForQueryMessage || msg is ErrorResponseMessage) {
      return true;
    }
    return !(msg is ParseCompleteMessage ||
        msg is BindCompleteMessage ||
        msg is ParameterDescriptionMessage ||
        msg is RowDescriptionMessage ||
        msg is NoDataMessage ||
        msg is DataRowMessage ||
        msg is CommandCompleteMessage ||
        msg is PortalSuspendedMessage ||
      msg is CloseCompletedMessage ||
      msg is EmptyQueryMessage);
  }

  Future<IBackendMessage> _readMessage() {
    // Legacy internal call, redirect to central handler to ensure we don't miss notifications
    return readMessage();
  }

  void _processPipelineMessage(IBackendMessage msg) {
    if (msg is ReadyForQueryMessage) {
      _handleReadyForQueryMessage();
    }

    if (_pipelineQueue == null || !_pipelineQueue!.inPipelineMode) {
      return;
    }

    final pendingCmd = _pipelineQueue!.peek();
    if (pendingCmd == null) {
      return;
    }

    if (msg is ParseCompleteMessage || msg is BindCompleteMessage) {
      pendingCmd.addMessage(msg);
      pendingCmd.recordResponse();
      return;
    }

    if (msg is RowDescriptionMessage || msg is NoDataMessage) {
      pendingCmd.addMessage(msg);
      pendingCmd.recordResponse();
      return;
    }

    if (msg is DataRowMessage) {
      pendingCmd.addMessage(msg);
      return;
    }

    if (msg is CommandCompleteMessage) {
      pendingCmd.addMessage(msg);
      pendingCmd.recordResponse();
      pendingCmd.markCompleted();
      _pipelineQueue!.removeCompleted();
      return;
    }

    if (msg is ErrorResponseMessage) {
      final err = msg.error;
      final exception = PostgresException(
        severity: err.severity ?? 'ERROR',
        invariantSeverity: err.invariantSeverity ?? err.severity ?? 'ERROR',
        sqlState: err.sqlState ?? '00000',
        messageText: err.messageText ?? 'Unknown Error',
      );
      pendingCmd.addMessage(msg);
      pendingCmd.markFailed(exception);
      _pipelineQueue!.removeCompleted();
      _pipelineQueue!.clear(exception);
      _pipelinePendingError = exception;
      _pipelinePendingErrorStack = StackTrace.current;
      _autoExitPipelineOnReady = true;
      _pipelineDrainingAfterError = true;
      return;
    }
  }

  void _handleReadyForQueryMessage() {
    final shouldExit =
        _autoExitPipelineOnReady || _pipelinePendingError != null;
    if (!shouldExit) {
      return;
    }

    _autoExitPipelineOnReady = false;
  _pipelineDrainingAfterError = false;

    final error = _pipelinePendingError;
    final stack = _pipelinePendingErrorStack;
    _pipelinePendingError = null;
    _pipelinePendingErrorStack = null;

    if (_pipelineQueue != null) {
      if (error != null) {
        _pipelineQueue!.clear(error, stack);
      } else {
        _pipelineQueue!.clear();
      }
      if (_pipelineQueue!.inPipelineMode) {
        _pipelineQueue!.exitPipelineMode();
      }
    }
  }

  /// Reads the next backend message belonging to the provided [PendingCommand].
  ///
  /// This will keep pumping the connector until the command produces a
  /// buffered message or completes (successfully or with error). Returns `null`
  /// once the command has no further messages to deliver.
  Future<IBackendMessage?> readMessageForPending(PendingCommand command) async {
    while (true) {
      final buffered = command.takeMessage();
      if (buffered != null) {
        return buffered;
      }
      if (command.isDone) {
        return null;
      }
      await readMessage();
    }
  }

  /// Creates a data reader that consumes the results of the provided pending
  /// pipeline commands sequentially.
  Future<NpgsqlDataReader> createPipelineReader(List<PendingCommand> commands,
      {bool drainReadyOnClose = true}) async {
    if (commands.isEmpty) {
      throw ArgumentError('commands cannot be empty');
    }
    final reader = NpgsqlDataReaderImpl(this,
        pendingCommands: commands, drainReadyOnClose: drainReadyOnClose);
    await reader.init();
    return reader;
  }

  /// Convenience helper to create a reader for a single pending command.
  Future<NpgsqlDataReader> createPipelineReaderForCommand(
      PendingCommand command) {
    return createPipelineReader([command], drainReadyOnClose: false);
  }

  Future<IBackendMessage> _readRawMessage() async {
    final raw = await _msgReader!.readMessage();
    return _backendReader.parse(raw);
  }

  Future<void> prepare(String sql, String statementName,
      NpgsqlParameterCollection parameters) async {
    // 1. Parse (Prepare)
    final paramOids = <int>[];
    for (final p in parameters) {
      if (p.value != null) {
        TypeHandler? handler;
        if (p.npgsqlDbType != null) {
          handler = _typeRegistry.resolveByNpgsqlDbType(p.npgsqlDbType!);
        }
        if (handler == null) {
          handler = _typeRegistry.resolveByValue(p.value);
        }
        paramOids.add(handler?.oid ?? 0);
      } else {
        paramOids.add(0); // Unknown/Unspecified
      }
    }

    await _frontendMessages!.writeParse(
      statementName: statementName,
      query: sql,
      parameterTypeOids: paramOids,
    );

    // 2. Describe Statement
    await _frontendMessages!.writeDescribeStatement(statementName);

    // 3. Sync
    await _frontendMessages!.writeSync();

    // 4. Consume responses
    while (true) {
      final msg = await _readMessage();
      if (msg is ParseCompleteMessage) continue;
      if (msg is ParameterDescriptionMessage) continue;
      if (msg is RowDescriptionMessage) continue;
      if (msg is NoDataMessage) continue;
      if (msg is ReadyForQueryMessage) break;
      if (msg is ErrorResponseMessage) {
        final err = msg.error;
        throw PostgresException(
            severity: err.severity ?? 'ERROR',
            invariantSeverity: err.invariantSeverity ?? err.severity ?? 'ERROR',
            sqlState: err.sqlState ?? '00000',
            messageText: err.messageText ?? 'Unknown Error');
      }
    }
  }

  Future<NpgsqlDataReader> executeReader(String sql,
      {NpgsqlParameterCollection? parameters, String? statementName}) async {
    if (parameters != null && parameters.isNotEmpty) {
      // Extended Query Protocol

      String sqlToExecute = sql;
      NpgsqlParameterCollection paramsToUse = parameters;

      // Rewrite SQL for @param if needed (only if not prepared statement)
      if (statementName == null) {
        final rewritten = SqlRewriter.rewrite(sql, parameters);
        sqlToExecute = rewritten.sql;
        paramsToUse = NpgsqlParameterCollection();
        paramsToUse.addAll(rewritten.orderedParameters);
      }

      if (statementName == null) {
        // Unnamed Statement Flow (Parse + Bind + Execute)
        final paramOids = <int>[];
        for (final p in paramsToUse) {
          final handler = _typeRegistry.resolveByValue(p.value);
          paramOids.add(handler?.oid ?? 0);
        }

        await _frontendMessages!
            .writeParse(query: sqlToExecute, parameterTypeOids: paramOids);
      } else {
        // Prepared Statement Flow (Bind + Execute using statementName)
        // We assume Parse was done via prepare()
        // We must use the parameters in the order they were prepared.
        // NpgsqlCommand handles the ordering before calling executeReader.
      }

      // 2. Bind
      final values = <Uint8List?>[];
      final formatCodes = <int>[];

      for (final p in paramsToUse) {
        if (p.value == null) {
          values.add(null);
          formatCodes.add(0); // null
        } else {
          final handler = _typeRegistry.resolveByValue(p.value);
          if (handler != null) {
            values.add(handler.write(p.value));
            formatCodes.add(1); // Binary
          } else {
            values.add(Uint8List.fromList(encoding.encode(p.value.toString())));
            formatCodes.add(0); // Text
          }
        }
      }

      await _frontendMessages!.writeBind(
        portalName: '',
        statementName: statementName ?? '',
        parameterValues: values,
        parameterFormatCodes: formatCodes,
        resultFormatCodes: [1], // Request Binary for all results
      );

      // 3. Describe
      await _frontendMessages!.writeDescribePortal('');

      // 4. Execute
      await _frontendMessages!.writeExecute();

      // 5. Sync
      await _frontendMessages!.writeSync();

      final reader = NpgsqlDataReaderImpl(this);
      await reader.init();
      return reader;
    } else {
      // Simple Query Protocol (Only if no parameters and no prepared statement)
      // If prepared statement is used but no parameters, we must use Extended Protocol too.
      if (statementName != null) {
        // Extended Protocol without parameters
        await _frontendMessages!.writeBind(
          portalName: '',
          statementName: statementName,
          resultFormatCodes: [1],
        );
        await _frontendMessages!.writeDescribePortal('');
        await _frontendMessages!.writeExecute();
        await _frontendMessages!.writeSync();

        final reader = NpgsqlDataReaderImpl(this);
        await reader.init();
        return reader;
      }

      await _frontendMessages!.writeQuery(sql);
      final reader = NpgsqlDataReaderImpl(this);
      await reader.init();
      return reader;
    }
  }

  Future<NpgsqlDataReader> executeBatch(NpgsqlBatch batch) async {
    if (batch.batchCommands.isEmpty) {
      throw ArgumentError('Batch cannot be empty');
    }

    // Use pipeline mode for efficient batch execution
    final wasInPipeline = inPipelineMode;
    if (!wasInPipeline) {
      enterPipelineMode();
    }

    final pendingCommands = <PendingCommand>[];

    try {
      for (final cmd in batch.batchCommands) {
        String sqlToExecute = cmd.commandText;
        NpgsqlParameterCollection paramsToUse = cmd.parameters;

        if (cmd.parameters.isNotEmpty) {
          final rewritten =
              SqlRewriter.rewrite(cmd.commandText, cmd.parameters);
          sqlToExecute = rewritten.sql;
          paramsToUse = NpgsqlParameterCollection();
          paramsToUse.addAll(rewritten.orderedParameters);
        }

        final pending = await executeQueryPipelined(
          sql: sqlToExecute,
          parameters: paramsToUse,
        );
        pendingCommands.add(pending);
      }

      await pipelineSync();
      if (!wasInPipeline) {
        scheduleAutoExitPipelineOnReady();
      }
    } catch (e) {
      if (!wasInPipeline && inPipelineMode) {
        cancelAutoExitPipelineOnReady();
        abortPipeline(e);
      }
      rethrow;
    }

    // Return reader
    return createPipelineReader(pendingCommands);
  }

  Future<CopyResponseMessage> executeCopyCommand(String sql) async {
    // Send Query
    await _frontendMessages!.writeQuery(sql);

    // Read responses until CopyInResponse
    while (true) {
      final msg = await _readMessage();
      if (msg is ErrorResponseMessage) {
        final err = msg.error;
        throw PostgresException(
            severity: err.severity ?? 'ERROR',
            invariantSeverity: err.invariantSeverity ?? err.severity ?? 'ERROR',
            sqlState: err.sqlState ?? '00000',
            messageText: err.messageText ?? 'Unknown Error');
      }

      if (msg is CopyResponseMessage) {
        return msg;
      }
      // Could be Notice, etc.
    }
  }

  Future<void> writeCopyData(Uint8List data) async {
    await _frontendMessages!.writeCopyData(data);
  }

  Future<void> sendStandbyStatus({
    required int walReceived,
    required int walFlushed,
    required int walApplied,
    required DateTime timestamp,
    bool replyRequested = false,
  }) async {
    await _frontendMessages!.writeStandbyStatusUpdate(
      walReceived: walReceived,
      walFlushed: walFlushed,
      walApplied: walApplied,
      timestamp: timestamp,
      replyRequested: replyRequested,
    );
  }

  Future<void> writeCopyDone() async {
    await _frontendMessages!.writeCopyDone();
  }

  Future<void> writeCopyFail(String msg) async {
    await _frontendMessages!.writeCopyFail(msg);
  }

  Future<Uint8List?> readCopyDataPacket() async {
    while (true) {
      final msg = await _readMessage();
      if (msg is CopyDataMessage) {
        return msg.data;
      }
      if (msg is CopyDoneMessage) {
        return null; // End of copy
      }
      if (msg is ErrorResponseMessage) {
        final err = msg.error;
        throw PostgresException(
            severity: err.severity ?? 'ERROR',
            invariantSeverity: err.invariantSeverity ?? err.severity ?? 'ERROR',
            sqlState: err.sqlState ?? '00000',
            messageText: err.messageText ?? 'Unknown Error');
      }
      // Ignore notices
    }
  }

  Future<void> awaitCopyComplete() async {
    bool seenCommandComplete = false;
    while (true) {
      final msg = await _readMessage();
      if (msg is CommandCompleteMessage) {
        seenCommandComplete = true;
        // In Simple Query protocol, we must also wait for ReadyForQuery
        continue;
      }
      if (msg is ReadyForQueryMessage) {
        if (seenCommandComplete) return;
        // If we got ReadyForQuery without CommandComplete, something is weird but we are ready.
        return;
      }
      if (msg is ErrorResponseMessage) {
        final err = msg.error;
        throw PostgresException(
            severity: err.severity ?? 'ERROR',
            invariantSeverity: err.invariantSeverity ?? err.severity ?? 'ERROR',
            sqlState: err.sqlState ?? '00000',
            messageText: err.messageText ?? 'Unknown Error');
      }
    }
  }

  // Pipeline Mode Support

  PipelineCommandQueue? _pipelineQueue;
  bool _autoExitPipelineOnReady = false;
  Object? _pipelinePendingError;
  StackTrace? _pipelinePendingErrorStack;
  bool _pipelineDrainingAfterError = false;

  /// Whether the connector is currently in pipeline mode.
  bool get inPipelineMode => _pipelineQueue?.inPipelineMode ?? false;

  /// Enter pipeline mode.
  void enterPipelineMode() {
    if (_pipelineQueue == null) {
      _pipelineQueue = PipelineCommandQueue();
    }
    _pipelineQueue!.enterPipelineMode();
    _autoExitPipelineOnReady = false;
  }

  /// Exit pipeline mode.
  void exitPipelineMode() {
    if (_pipelineQueue == null || !_pipelineQueue!.inPipelineMode) {
      throw StateError('Not in pipeline mode');
    }
    _pipelineQueue!.exitPipelineMode();
    _autoExitPipelineOnReady = false;
  }

  /// Send a Sync message to terminate the current pipeline batch.
  Future<void> pipelineSync() async {
    if (!inPipelineMode) {
      throw StateError('Not in pipeline mode');
    }

    // Send Sync message
    await _frontendMessages!.writeSync(flush: false);
    if (_msgWriter != null) {
      await _msgWriter!.flush();
    } else if (_writeBuffer != null) {
      await _writeBuffer!.flush();
    }
  }

  /// Execute a query in pipeline mode (send without awaiting server response).
  /// Returns a [PendingCommand] that can be used to track completion.
  /// Must be in pipeline mode before calling this.
  Future<PendingCommand> executeQueryPipelined({
    required String sql,
    String? statementName,
    NpgsqlParameterCollection? parameters,
  }) async {
    if (!inPipelineMode) {
      throw StateError('Not in pipeline mode. Call enterPipelineMode() first.');
    }

    // Calculate expected response count:
    // - If using prepared statement: BindComplete(1) + RowDescription(1) + DataRow(*) + CommandComplete(1)
    // - Parse: ParseComplete(1)
    // - We'll start with a conservative estimate
    int expectedResponses =
        3; // ParseComplete/BindComplete + RowDescription/NoData + CommandComplete

    final pendingCmd = PendingCommand(
      sql: sql,
      statementName: statementName,
      expectedResponseCount: expectedResponses,
    );

    _pipelineQueue!.enqueue(pendingCmd);

    // Send Parse, Bind, Execute without forcing a flush
    await _sendQueryMessages(
      sql: sql,
      statementName: statementName,
      parameters: parameters,
    );

    return pendingCmd;
  }

  /// Send Parse/Bind/Execute messages without triggering an immediate flush.
  /// This is used for pipeline mode.
  Future<void> _sendQueryMessages({
    required String sql,
    String? statementName,
    NpgsqlParameterCollection? parameters,
  }) async {
    final params = parameters ?? NpgsqlParameterCollection();

    // Collect parameter OIDs and values
    final paramOids = <int>[];
    final paramValues = <dynamic>[];
    final paramHandlers = <TypeHandler?>[];

    for (final p in params) {
      TypeHandler? handler;
      if (p.npgsqlDbType != null) {
        handler = _typeRegistry.resolveByNpgsqlDbType(p.npgsqlDbType!);
      }
      if (handler == null) {
        handler = _typeRegistry.resolveByValue(p.value);
      }
      paramOids.add(handler?.oid ?? 0);
      paramValues.add(p.value);
      paramHandlers.add(handler);
    }

    // Write Parse if not already prepared
    if (statementName == null || statementName.isEmpty) {
      await _frontendMessages!.writeParse(
        statementName: '',
        query: sql,
        parameterTypeOids: paramOids,
        flush: false,
      );
    }

    // Write Bind
    final encodedParams = <List<int>?>[];
    final parameterFormatCodes = <int>[];
    for (var i = 0; i < paramValues.length; i++) {
      final value = paramValues[i];
      final handler = paramHandlers[i];
      if (value == null) {
        encodedParams.add(null);
        parameterFormatCodes.add(0);
      } else if (handler != null) {
        encodedParams.add(handler.write(value));
        parameterFormatCodes.add(1);
      } else {
        encodedParams.add(encoding.encode(value.toString()));
        parameterFormatCodes.add(0);
      }
    }

    await _frontendMessages!.writeBind(
      portalName: '',
      statementName: statementName ?? '',
      parameterFormatCodes: parameterFormatCodes,
      parameterValues: encodedParams,
      resultFormatCodes: [1], // Binary format
      flush: false,
    );

    // Write Describe to ensure RowDescription before DataRow
    await _frontendMessages!.writeDescribePortal('', flush: false);

    // Write Execute
    await _frontendMessages!.writeExecute(
      portalName: '',
      maxRows: 0,
      flush: false,
    );

    // Note: We do NOT send Sync or flush here
    // The caller must call pipelineSync() when ready
  }

  /// Flush the write buffer without sending Sync.
  /// Used in pipeline mode to send accumulated commands to the server.
  Future<void> flushPipeline() async {
    if (_msgWriter != null) {
      await _msgWriter!.flush();
    } else if (_writeBuffer != null) {
      await _writeBuffer!.flush();
    }
  }

  /// Get the current pipeline queue (for debugging/monitoring).
  PipelineCommandQueue? get pipelineQueue => _pipelineQueue;

  /// Schedules automatic exit from pipeline mode once ReadyForQuery arrives.
  void scheduleAutoExitPipelineOnReady() {
    _autoExitPipelineOnReady = true;
  }

  /// Cancels any previously scheduled automatic exit from pipeline mode.
  void cancelAutoExitPipelineOnReady() {
    _autoExitPipelineOnReady = false;
  }

  /// Aborts the current pipeline, failing all pending commands and
  /// attempting to exit pipeline mode.
  void abortPipeline(Object error, [StackTrace? stackTrace]) {
    _pipelineQueue?.clear(error, stackTrace);
    _autoExitPipelineOnReady = false;
    _pipelinePendingError = null;
    _pipelinePendingErrorStack = null;
    if (_pipelineQueue != null && _pipelineQueue!.inPipelineMode) {
      try {
        _pipelineQueue!.exitPipelineMode();
      } catch (_) {
        // Ignore to avoid masking original error.
      }
    }
  }
}
