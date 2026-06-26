import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';

import '../io/binary_input.dart';
import '../io/binary_output.dart';
import '../protocol/backend_messages.dart';
import '../protocol/frontend_messages.dart';
import '../protocol/postgres_message.dart';
import '../postgres_exception.dart';
import '../dpgsql_data_reader.dart';
import '../dpgsql_parameter_collection.dart';
import '../pg_result_mode.dart';
import '../data/pg_row.dart';
import '../types/oid.dart';
import '../types/type_handler.dart';
import '../dpgsql_batch.dart';
import '../dpgsql_batch_command.dart';
import '../crypto/crypto.dart';
import 'dpgsql_data_reader_impl.dart';
import 'scram_authenticator.dart';
import 'sql_rewriter.dart';
import 'pipeline_command_queue.dart';
import 'pending_command.dart';
import 'prepared_statement.dart';
import '../dpgsql_notification_event_args.dart';
import '../ssl_mode.dart';
import '../timezone_settings.dart';
import 'timezone_helper.dart';

/// Represents a connection to a PostgreSQL backend.
/// Porting DpgsqlConnector.cs
class DpgsqlConnector {
  DpgsqlConnector({
    required this.host,
    this.port = 5432,
    this.username = 'postgres',
    this.password = '',
    this.database = 'postgres',
    this.sslMode = SslMode.disable,
    this.trustServerCertificate = false,
    this.encoding = utf8,
    this.clientEncoding,
    TimeZoneSettings? timeZone,
    this.replication = false,
    int maxAutoPrepare = 0,
    int autoPrepareMinUsages = 5,
  })  : timeZone = timeZone ?? const TimeZoneSettings.utc(),
        preparedStatementManager = PreparedStatementManager(
          maxAutoPrepared: maxAutoPrepare,
          usagesBeforeAutoPrepare: autoPrepareMinUsages,
        ),
        _typeRegistry = TypeHandlerRegistry(
          timeZone: timeZone ?? const TimeZoneSettings.utc(),
        );

  final String host;
  final int port;
  final String username;
  final String password;
  final String database;
  final SslMode sslMode;
  final bool trustServerCertificate;
  final Encoding encoding;
  final String? clientEncoding;
  final TimeZoneSettings timeZone;
  final bool replication;
  final PreparedStatementManager preparedStatementManager;

  Socket? _socket;
  SocketBinaryInput? _readBuffer;
  SocketBinaryOutput? _writeBuffer;

  PostgresMessageReader? _msgReader;
  PostgresMessageWriter? _msgWriter;

  final TypeHandlerRegistry _typeRegistry;
  final Map<String, RowDescriptionMessage> _preparedRowDescriptions = {};

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
              // Dpgsql docs: "Prefer: ... If SSL is used, the server certificate is validated."
              // So if validation fails, we should reject, unless TrustServerCertificate is true.

              // However, historically 'Allow' might have been loose.
              // But standard Dpgsql behavior is: if SSL is negotiated, validation happens unless TrustServerCertificate=true.

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
    _readBuffer?.dispose();
    _readBuffer = null;
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
    if (clientEncoding != null && clientEncoding!.isNotEmpty) {
      params['client_encoding'] = clientEncoding!;
    }
    if (timeZone.value.isNotEmpty) {
      params['TimeZone'] = timeZone.value;
    }
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
    final step1 = md5(utf8.encode(password + user));
    final hex1Bytes = utf8.encode(bytesToHex(step1));
    final step2 = md5(Uint8List.fromList([...hex1Bytes, ...salt]));
    return 'md5${bytesToHex(step2)}';
  }

  final _notificationController =
      StreamController<DpgsqlNotificationEventArgs>.broadcast();
  Stream<DpgsqlNotificationEventArgs> get notifications =>
      _notificationController.stream;

  final _noticeController = StreamController<ErrorOrNoticeMessage>.broadcast();
  Stream<ErrorOrNoticeMessage> get notices => _noticeController.stream;

  Future<IBackendMessage> readMessage() async {
    while (true) {
      final msg = await _readRawMessage();

      _processPipelineMessage(msg);

      if (_pipelineDrainingAfterError && !_shouldDeliverWhileDraining(msg)) {
        continue;
      }

      if (msg is NotificationResponseMessage) {
        _notificationController.add(DpgsqlNotificationEventArgs(
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

  int _parseRecordsAffected(String commandTag) {
    if (commandTag.isEmpty) return 0;
    final parts = commandTag.split(' ');
    for (var i = parts.length - 1; i >= 0; i--) {
      final value = int.tryParse(parts[i]);
      if (value != null) {
        return value;
      }
    }
    return 0;
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
      pendingCmd.commandTag = msg.commandTag;
      pendingCmd.recordsAffected = _parseRecordsAffected(msg.commandTag);
      final batchCmd = pendingCmd.batchCommand;
      if (batchCmd != null) {
        batchCmd.commandTag = msg.commandTag;
        batchCmd.recordsAffected = pendingCmd.recordsAffected;
      }
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
  Future<DpgsqlDataReader> createPipelineReader(List<PendingCommand> commands,
      {bool drainReadyOnClose = true,
      List<DpgsqlBatchCommand>? batchCommands}) async {
    if (commands.isEmpty) {
      throw ArgumentError('commands cannot be empty');
    }
    final reader = DpgsqlDataReaderImpl(this,
        pendingCommands: commands,
        drainReadyOnClose: drainReadyOnClose,
        batchCommands: batchCommands,
        resultMode: commands.first.resultMode);
    await reader.init();
    return reader;
  }

  /// Convenience helper to create a reader for a single pending command.
  Future<DpgsqlDataReader> createPipelineReaderForCommand(
      PendingCommand command) {
    return createPipelineReader([command], drainReadyOnClose: false);
  }

  Future<IBackendMessage> _readRawMessage() async {
    final raw = await _msgReader!.readMessage();
    return _backendReader.parse(raw);
  }

  Future<void> prepare(String sql, String statementName,
      DpgsqlParameterCollection parameters) async {
    // 1. Parse (Prepare)
    final paramOids = <int>[];
    for (final p in parameters) {
      if (p.value != null) {
        TypeHandler? handler;
        if (p.dpgsqlDbType != null) {
          handler = _typeRegistry.resolveByDpgsqlDbType(p.dpgsqlDbType!);
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
      flush: false,
    );

    // 2. Describe Statement
    await _frontendMessages!
        .writeDescribeStatement(statementName, flush: false);

    // 3. Sync
    await _frontendMessages!.writeSync();

    // 4. Consume responses
    while (true) {
      final msg = await _readMessage();
      if (msg is ParseCompleteMessage) continue;
      if (msg is ParameterDescriptionMessage) continue;
      if (msg is RowDescriptionMessage) {
        _preparedRowDescriptions[statementName] = msg;
        continue;
      }
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

  Future<DpgsqlDataReader> executeReader(String sql,
      {DpgsqlParameterCollection? parameters,
      String? statementName,
      bool rewriteParameters = true,
      PgResultMode resultMode = PgResultMode.typed}) async {
    final resultFormatCode = resultMode == PgResultMode.rawText ? 0 : 1;
    if (parameters != null && parameters.isNotEmpty) {
      // Extended Query Protocol

      String sqlToExecute = sql;
      DpgsqlParameterCollection paramsToUse = parameters;

      // Rewrite SQL for @param if needed (only if not prepared statement)
      if (statementName == null && rewriteParameters) {
        final rewritten = SqlRewriter.rewrite(sql, parameters);
        sqlToExecute = rewritten.sql;
        paramsToUse = DpgsqlParameterCollection();
        paramsToUse.addAll(rewritten.orderedParameters);
      }

      final paramHandlers = <TypeHandler?>[];
      for (final p in paramsToUse) {
        TypeHandler? handler;
        if (p.value != null) {
          if (p.dpgsqlDbType != null) {
            handler = _typeRegistry.resolveByDpgsqlDbType(p.dpgsqlDbType!);
          }
          handler ??= _typeRegistry.resolveByValue(p.value);
        }
        paramHandlers.add(handler);
      }

      final paramOids = <int>[];
      for (final handler in paramHandlers) {
        paramOids.add(handler?.oid ?? 0);
      }

      var statementNameToUse = statementName;
      PreparedStatement? autoPrepareStatement;

      if (statementName == null) {
        if (preparedStatementManager.maxAutoPrepared > 0) {
          final prepared = preparedStatementManager.tryGetPreparedStatement(
            sqlToExecute,
            paramOids,
          );
          if (prepared != null) {
            statementNameToUse = prepared.name;
          } else {
            final candidate = preparedStatementManager
                .tryGetOrCreateAutoPrepareCandidate(sqlToExecute, paramOids);
            if (candidate != null) {
              autoPrepareStatement = preparedStatementManager.beginAutoPrepare(
                candidate,
                paramOids,
              );
              statementNameToUse = autoPrepareStatement?.name;
            }
          }
        }

        await _writePendingUnprepareMessages();

        if (autoPrepareStatement != null) {
          await _frontendMessages!.writeParse(
            statementName: statementNameToUse ?? '',
            query: sqlToExecute,
            parameterTypeOids: paramOids,
            flush: false,
          );
        } else if (statementNameToUse == null) {
          // Unnamed Statement Flow (Parse + Bind + Execute)
          await _frontendMessages!.writeParse(
            query: sqlToExecute,
            parameterTypeOids: paramOids,
            flush: false,
          );
        }
      } else {
        // Prepared Statement Flow (Bind + Execute using statementName)
        // We assume Parse was done via prepare()
        // We must use the parameters in the order they were prepared.
        // DpgsqlCommand handles the ordering before calling executeReader.
      }

      // 2. Bind
      final values = <Uint8List?>[];
      final formatCodes = <int>[];

      for (var i = 0; i < paramsToUse.length; i++) {
        final p = paramsToUse[i];
        if (p.value == null) {
          values.add(null);
          formatCodes.add(0); // null
        } else {
          final handler = paramHandlers[i];
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
        statementName: statementNameToUse ?? '',
        parameterValues: values,
        parameterFormatCodes: formatCodes,
        resultFormatCodes: [resultFormatCode],
        flush: false,
      );

      // 3. Describe
      await _frontendMessages!.writeDescribePortal('', flush: false);

      // 4. Execute
      await _frontendMessages!.writeExecute(flush: false);

      // 5. Sync
      await _frontendMessages!.writeSync();

      final reader = DpgsqlDataReaderImpl(this, resultMode: resultMode);
      try {
        await reader.init();
        if (autoPrepareStatement != null) {
          preparedStatementManager.completeAutoPrepare(autoPrepareStatement);
        }
      } catch (_) {
        if (autoPrepareStatement != null) {
          autoPrepareStatement.abortPrepare();
        }
        rethrow;
      }
      return reader;
    } else {
      // Simple Query Protocol (Only if no parameters and no prepared statement)
      // If prepared statement is used but no parameters, we must use Extended Protocol too.
      if (statementName != null) {
        // Extended Protocol without parameters
        await _frontendMessages!.writeBind(
          portalName: '',
          statementName: statementName,
          resultFormatCodes: [resultFormatCode],
          flush: false,
        );
        await _frontendMessages!.writeDescribePortal('', flush: false);
        await _frontendMessages!.writeExecute(flush: false);
        await _frontendMessages!.writeSync();

        final reader = DpgsqlDataReaderImpl(this, resultMode: resultMode);
        await reader.init();
        return reader;
      }

      await _frontendMessages!.writeQuery(sql);
      final reader = DpgsqlDataReaderImpl(this, resultMode: resultMode);
      await reader.init();
      return reader;
    }
  }

  Future<List<List<Object?>>> executeRows(
    String sql, {
    DpgsqlParameterCollection? parameters,
    String? statementName,
    bool rewriteParameters = true,
  }) async {
    final preparedDescription =
        statementName == null ? null : _preparedRowDescriptions[statementName];
    if (preparedDescription != null) {
      return _executePreparedRowsFast(
        statementName!,
        parameters,
        preparedDescription,
      );
    }

    final reader = await executeReader(
      sql,
      parameters: parameters,
      statementName: statementName,
      rewriteParameters: rewriteParameters,
    );
    if (reader is DpgsqlDataReaderImpl) {
      return reader.readAllRows();
    }

    final rows = <List<Object?>>[];
    try {
      while (await reader.read()) {
        rows.add(List<Object?>.generate(
          reader.fieldCount,
          reader.getValue,
          growable: false,
        ));
      }
      return rows;
    } finally {
      await reader.close();
    }
  }

  Future<List<Map<String, dynamic>>> executeMaps(
    String sql, {
    DpgsqlParameterCollection? parameters,
    String? statementName,
    bool rewriteParameters = true,
    PgResultMode resultMode = PgResultMode.typed,
  }) async {
    final preparedDescription =
        statementName == null ? null : _preparedRowDescriptions[statementName];
    if (preparedDescription != null) {
      if (resultMode == PgResultMode.rawText) {
        return _executePreparedMapsRawTextFast(
          statementName!,
          parameters,
          preparedDescription,
        );
      }
      return _executePreparedMapsFast(
        statementName!,
        parameters,
        preparedDescription,
      );
    }

    final reader = await executeReader(
      sql,
      parameters: parameters,
      statementName: statementName,
      rewriteParameters: rewriteParameters,
      resultMode: resultMode,
    );
    if (reader is DpgsqlDataReaderImpl) {
      return reader.readAllMaps();
    }

    final rows = <Map<String, dynamic>>[];
    try {
      while (await reader.read()) {
        rows.add(reader.toMap());
      }
      return rows;
    } finally {
      await reader.close();
    }
  }

  Future<List<PgRow>> executePgRows(
    String sql, {
    DpgsqlParameterCollection? parameters,
    String? statementName,
    bool rewriteParameters = true,
  }) async {
    final preparedDescription =
        statementName == null ? null : _preparedRowDescriptions[statementName];
    if (preparedDescription != null) {
      return _executePreparedPgRowsFast(
        statementName!,
        parameters,
        preparedDescription,
      );
    }

    final reader = await executeReader(
      sql,
      parameters: parameters,
      statementName: statementName,
      rewriteParameters: rewriteParameters,
    );
    try {
      final rows = <PgRow>[];
      while (await reader.read()) {
        final values = <Uint8List?>[];
        for (var i = 0; i < reader.fieldCount; i++) {
          final value = reader.getValue(i);
          values.add(value == null
              ? null
              : Uint8List.fromList(encoding.encode(value.toString())));
        }
        final builder = PgRowBuilder(
          columnNames: List<String>.generate(
            reader.fieldCount,
            (i) => 'column_$i',
            growable: false,
          ),
          columnTypes: List<int>.filled(reader.fieldCount, 0),
          timeZone: timeZone,
        );
        for (var i = 0; i < values.length; i++) {
          builder.addColumn(values[i], i);
        }
        rows.add(builder.build());
      }
      return rows;
    } finally {
      await reader.close();
    }
  }

  Future<void> forEachPgRow(
    String sql,
    FutureOr<void> Function(PgRow row) action, {
    DpgsqlParameterCollection? parameters,
    String? statementName,
    bool rewriteParameters = true,
  }) async {
    final preparedDescription =
        statementName == null ? null : _preparedRowDescriptions[statementName];
    if (preparedDescription != null) {
      return _forEachPreparedPgRowFast(
        statementName!,
        parameters,
        preparedDescription,
        action,
      );
    }

    final rows = await executePgRows(
      sql,
      parameters: parameters,
      statementName: statementName,
      rewriteParameters: rewriteParameters,
    );
    for (final row in rows) {
      final result = action(row);
      if (result is Future) {
        await result;
      }
    }
  }

  Future<void> forEachPgRowSync(
    String sql,
    void Function(PgRow row) action, {
    DpgsqlParameterCollection? parameters,
    String? statementName,
    bool rewriteParameters = true,
  }) async {
    final preparedDescription =
        statementName == null ? null : _preparedRowDescriptions[statementName];
    if (preparedDescription != null) {
      return _forEachPreparedPgRowFastSync(
        statementName!,
        parameters,
        preparedDescription,
        action,
      );
    }

    final rows = await executePgRows(
      sql,
      parameters: parameters,
      statementName: statementName,
      rewriteParameters: rewriteParameters,
    );
    for (final row in rows) {
      action(row);
    }
  }

  Future<List<Map<String, dynamic>>> _executePreparedMapsFast(
    String statementName,
    DpgsqlParameterCollection? parameters,
    RowDescriptionMessage rowDescription,
  ) async {
    final params = parameters ?? DpgsqlParameterCollection();
    final parameterValues = <Uint8List?>[];
    final parameterFormatCodes = <int>[];

    for (final p in params) {
      if (p.value == null) {
        parameterValues.add(null);
        parameterFormatCodes.add(0);
        continue;
      }

      TypeHandler? handler;
      if (p.dpgsqlDbType != null) {
        handler = _typeRegistry.resolveByDpgsqlDbType(p.dpgsqlDbType!);
      }
      handler ??= _typeRegistry.resolveByValue(p.value);

      if (handler != null) {
        parameterValues.add(handler.write(p.value));
        parameterFormatCodes.add(1);
      } else {
        parameterValues.add(Uint8List.fromList(encoding.encode('${p.value}')));
        parameterFormatCodes.add(0);
      }
    }

    await _frontendMessages!.writeBind(
      portalName: '',
      statementName: statementName,
      parameterFormatCodes: parameterFormatCodes,
      parameterValues: parameterValues,
      resultFormatCodes: [1],
      flush: false,
    );
    await _frontendMessages!.writeExecute(flush: false);
    await _frontendMessages!.writeSync();

    final fields = rowDescription.fields;
    final columnNames = List<String>.generate(
      fields.length,
      (i) => fields[i].name,
      growable: false,
    );
    final handlers = List<TypeHandler?>.filled(fields.length, null);
    final oids = List<int>.filled(fields.length, 0);
    for (var i = 0; i < fields.length; i++) {
      final oid = fields[i].oid;
      oids[i] = oid;
      handlers[i] = _typeRegistry.resolve(oid);
    }

    final rows = <Map<String, dynamic>>[];
    while (true) {
      final msg = await readMessage();
      if (msg is BindCompleteMessage ||
          msg is ParseCompleteMessage ||
          msg is CloseCompletedMessage ||
          msg is ParameterDescriptionMessage ||
          msg is NoDataMessage) {
        continue;
      }
      if (msg is DataRowMessage) {
        rows.add(_decodeMaterializedMap(msg, columnNames, oids, handlers));
        continue;
      }
      if (msg is CommandCompleteMessage || msg is RowDescriptionMessage) {
        continue;
      }
      if (msg is ReadyForQueryMessage) {
        return rows;
      }
      if (msg is ErrorResponseMessage) {
        final err = msg.error;
        throw PostgresException(
          severity: err.severity ?? 'ERROR',
          invariantSeverity: err.invariantSeverity ?? err.severity ?? 'ERROR',
          sqlState: err.sqlState ?? '00000',
          messageText: err.messageText ?? 'Unknown Error',
          detail: err.detail,
          hint: err.hint,
        );
      }
    }
  }

  Future<List<Map<String, dynamic>>> _executePreparedMapsRawTextFast(
    String statementName,
    DpgsqlParameterCollection? parameters,
    RowDescriptionMessage rowDescription,
  ) async {
    final params = parameters ?? DpgsqlParameterCollection();
    final parameterValues = <Uint8List?>[];
    final parameterFormatCodes = <int>[];

    for (final p in params) {
      if (p.value == null) {
        parameterValues.add(null);
        parameterFormatCodes.add(0);
        continue;
      }

      TypeHandler? handler;
      if (p.dpgsqlDbType != null) {
        handler = _typeRegistry.resolveByDpgsqlDbType(p.dpgsqlDbType!);
      }
      handler ??= _typeRegistry.resolveByValue(p.value);

      if (handler != null) {
        parameterValues.add(handler.write(p.value));
        parameterFormatCodes.add(1);
      } else {
        parameterValues.add(Uint8List.fromList(encoding.encode('${p.value}')));
        parameterFormatCodes.add(0);
      }
    }

    await _frontendMessages!.writeBind(
      portalName: '',
      statementName: statementName,
      parameterFormatCodes: parameterFormatCodes,
      parameterValues: parameterValues,
      resultFormatCodes: [0],
      flush: false,
    );
    await _frontendMessages!.writeExecute(flush: false);
    await _frontendMessages!.writeSync();

    final fields = rowDescription.fields;
    final columnNames = List<String>.generate(
      fields.length,
      (i) => fields[i].name,
      growable: false,
    );

    final rows = <Map<String, dynamic>>[];
    while (true) {
      final msg = await readMessage();
      if (msg is BindCompleteMessage ||
          msg is ParseCompleteMessage ||
          msg is CloseCompletedMessage ||
          msg is ParameterDescriptionMessage ||
          msg is NoDataMessage ||
          msg is CommandCompleteMessage ||
          msg is RowDescriptionMessage) {
        continue;
      }
      if (msg is DataRowMessage) {
        rows.add(_decodeMaterializedRawTextMap(msg, columnNames));
        continue;
      }
      if (msg is ReadyForQueryMessage) {
        return rows;
      }
      if (msg is ErrorResponseMessage) {
        final err = msg.error;
        throw PostgresException(
          severity: err.severity ?? 'ERROR',
          invariantSeverity: err.invariantSeverity ?? err.severity ?? 'ERROR',
          sqlState: err.sqlState ?? '00000',
          messageText: err.messageText ?? 'Unknown Error',
          detail: err.detail,
          hint: err.hint,
        );
      }
    }
  }

  Future<List<PgRow>> _executePreparedPgRowsFast(
    String statementName,
    DpgsqlParameterCollection? parameters,
    RowDescriptionMessage rowDescription,
  ) async {
    final params = parameters ?? DpgsqlParameterCollection();
    final parameterValues = <Uint8List?>[];
    final parameterFormatCodes = <int>[];

    for (final p in params) {
      if (p.value == null) {
        parameterValues.add(null);
        parameterFormatCodes.add(0);
        continue;
      }

      TypeHandler? handler;
      if (p.dpgsqlDbType != null) {
        handler = _typeRegistry.resolveByDpgsqlDbType(p.dpgsqlDbType!);
      }
      handler ??= _typeRegistry.resolveByValue(p.value);

      if (handler != null) {
        parameterValues.add(handler.write(p.value));
        parameterFormatCodes.add(1);
      } else {
        parameterValues.add(Uint8List.fromList(encoding.encode('${p.value}')));
        parameterFormatCodes.add(0);
      }
    }

    await _frontendMessages!.writeBind(
      portalName: '',
      statementName: statementName,
      parameterFormatCodes: parameterFormatCodes,
      parameterValues: parameterValues,
      resultFormatCodes: [1],
      flush: false,
    );
    await _frontendMessages!.writeExecute(flush: false);
    await _frontendMessages!.writeSync();

    final fields = rowDescription.fields;
    final columnNames = List<String>.generate(
      fields.length,
      (i) => fields[i].name,
      growable: false,
    );
    final columnTypes = List<int>.generate(
      fields.length,
      (i) => fields[i].oid,
      growable: false,
    );
    final rows = <PgRow>[];

    while (true) {
      final msg = await readMessage();
      if (msg is BindCompleteMessage ||
          msg is ParseCompleteMessage ||
          msg is CloseCompletedMessage ||
          msg is ParameterDescriptionMessage ||
          msg is NoDataMessage ||
          msg is CommandCompleteMessage ||
          msg is RowDescriptionMessage) {
        continue;
      }
      if (msg is DataRowMessage) {
        rows.add(PgRow(
          buffer: Uint8List.fromList(msg.payload),
          columnOffsets: Int32List.fromList(msg.columnOffsets),
          columnLengths: Int32List.fromList(msg.columnLengths),
          columnNames: columnNames,
          columnTypes: columnTypes,
          timeZone: timeZone,
        ));
        continue;
      }
      if (msg is ReadyForQueryMessage) {
        return rows;
      }
      if (msg is ErrorResponseMessage) {
        final err = msg.error;
        throw PostgresException(
          severity: err.severity ?? 'ERROR',
          invariantSeverity: err.invariantSeverity ?? err.severity ?? 'ERROR',
          sqlState: err.sqlState ?? '00000',
          messageText: err.messageText ?? 'Unknown Error',
          detail: err.detail,
          hint: err.hint,
        );
      }
    }
  }

  Future<void> _forEachPreparedPgRowFast(
    String statementName,
    DpgsqlParameterCollection? parameters,
    RowDescriptionMessage rowDescription,
    FutureOr<void> Function(PgRow row) action,
  ) async {
    final params = parameters ?? DpgsqlParameterCollection();
    final parameterValues = <Uint8List?>[];
    final parameterFormatCodes = <int>[];

    for (final p in params) {
      if (p.value == null) {
        parameterValues.add(null);
        parameterFormatCodes.add(0);
        continue;
      }

      TypeHandler? handler;
      if (p.dpgsqlDbType != null) {
        handler = _typeRegistry.resolveByDpgsqlDbType(p.dpgsqlDbType!);
      }
      handler ??= _typeRegistry.resolveByValue(p.value);

      if (handler != null) {
        parameterValues.add(handler.write(p.value));
        parameterFormatCodes.add(1);
      } else {
        parameterValues.add(Uint8List.fromList(encoding.encode('${p.value}')));
        parameterFormatCodes.add(0);
      }
    }

    await _frontendMessages!.writeBind(
      portalName: '',
      statementName: statementName,
      parameterFormatCodes: parameterFormatCodes,
      parameterValues: parameterValues,
      resultFormatCodes: [1],
      flush: false,
    );
    await _frontendMessages!.writeExecute(flush: false);
    await _frontendMessages!.writeSync();

    final fields = rowDescription.fields;
    final columnNames = List<String>.generate(
      fields.length,
      (i) => fields[i].name,
      growable: false,
    );
    final columnTypes = List<int>.generate(
      fields.length,
      (i) => fields[i].oid,
      growable: false,
    );

    while (true) {
      final msg = await readMessage();
      if (msg is BindCompleteMessage ||
          msg is ParseCompleteMessage ||
          msg is CloseCompletedMessage ||
          msg is ParameterDescriptionMessage ||
          msg is NoDataMessage ||
          msg is CommandCompleteMessage ||
          msg is RowDescriptionMessage) {
        continue;
      }
      if (msg is DataRowMessage) {
        final result = action(PgRow(
          buffer: msg.payload,
          columnOffsets: msg.columnOffsets,
          columnLengths: msg.columnLengths,
          columnNames: columnNames,
          columnTypes: columnTypes,
          timeZone: timeZone,
        ));
        if (result is Future) {
          await result;
        }
        continue;
      }
      if (msg is ReadyForQueryMessage) {
        return;
      }
      if (msg is ErrorResponseMessage) {
        final err = msg.error;
        throw PostgresException(
          severity: err.severity ?? 'ERROR',
          invariantSeverity: err.invariantSeverity ?? err.severity ?? 'ERROR',
          sqlState: err.sqlState ?? '00000',
          messageText: err.messageText ?? 'Unknown Error',
          detail: err.detail,
          hint: err.hint,
        );
      }
    }
  }

  Future<void> _forEachPreparedPgRowFastSync(
    String statementName,
    DpgsqlParameterCollection? parameters,
    RowDescriptionMessage rowDescription,
    void Function(PgRow row) action,
  ) async {
    final params = parameters ?? DpgsqlParameterCollection();
    final parameterValues = <Uint8List?>[];
    final parameterFormatCodes = <int>[];

    for (final p in params) {
      if (p.value == null) {
        parameterValues.add(null);
        parameterFormatCodes.add(0);
        continue;
      }

      TypeHandler? handler;
      if (p.dpgsqlDbType != null) {
        handler = _typeRegistry.resolveByDpgsqlDbType(p.dpgsqlDbType!);
      }
      handler ??= _typeRegistry.resolveByValue(p.value);

      if (handler != null) {
        parameterValues.add(handler.write(p.value));
        parameterFormatCodes.add(1);
      } else {
        parameterValues.add(Uint8List.fromList(encoding.encode('${p.value}')));
        parameterFormatCodes.add(0);
      }
    }

    await _frontendMessages!.writeBind(
      portalName: '',
      statementName: statementName,
      parameterFormatCodes: parameterFormatCodes,
      parameterValues: parameterValues,
      resultFormatCodes: [1],
      flush: false,
    );
    await _frontendMessages!.writeExecute(flush: false);
    await _frontendMessages!.writeSync();

    final fields = rowDescription.fields;
    final columnNames = List<String>.generate(
      fields.length,
      (i) => fields[i].name,
      growable: false,
    );
    final columnTypes = List<int>.generate(
      fields.length,
      (i) => fields[i].oid,
      growable: false,
    );

    while (true) {
      final msg = await readMessage();
      if (msg is BindCompleteMessage ||
          msg is ParseCompleteMessage ||
          msg is CloseCompletedMessage ||
          msg is ParameterDescriptionMessage ||
          msg is NoDataMessage ||
          msg is CommandCompleteMessage ||
          msg is RowDescriptionMessage) {
        continue;
      }
      if (msg is DataRowMessage) {
        action(PgRow(
          buffer: msg.payload,
          columnOffsets: msg.columnOffsets,
          columnLengths: msg.columnLengths,
          columnNames: columnNames,
          columnTypes: columnTypes,
          timeZone: timeZone,
        ));
        continue;
      }
      if (msg is ReadyForQueryMessage) {
        return;
      }
      if (msg is ErrorResponseMessage) {
        final err = msg.error;
        throw PostgresException(
          severity: err.severity ?? 'ERROR',
          invariantSeverity: err.invariantSeverity ?? err.severity ?? 'ERROR',
          sqlState: err.sqlState ?? '00000',
          messageText: err.messageText ?? 'Unknown Error',
          detail: err.detail,
          hint: err.hint,
        );
      }
    }
  }

  Future<List<List<Object?>>> _executePreparedRowsFast(
    String statementName,
    DpgsqlParameterCollection? parameters,
    RowDescriptionMessage rowDescription,
  ) async {
    final params = parameters ?? DpgsqlParameterCollection();
    final parameterValues = <Uint8List?>[];
    final parameterFormatCodes = <int>[];

    for (final p in params) {
      if (p.value == null) {
        parameterValues.add(null);
        parameterFormatCodes.add(0);
        continue;
      }

      TypeHandler? handler;
      if (p.dpgsqlDbType != null) {
        handler = _typeRegistry.resolveByDpgsqlDbType(p.dpgsqlDbType!);
      }
      handler ??= _typeRegistry.resolveByValue(p.value);

      if (handler != null) {
        parameterValues.add(handler.write(p.value));
        parameterFormatCodes.add(1);
      } else {
        parameterValues.add(Uint8List.fromList(encoding.encode('${p.value}')));
        parameterFormatCodes.add(0);
      }
    }

    await _frontendMessages!.writeBind(
      portalName: '',
      statementName: statementName,
      parameterFormatCodes: parameterFormatCodes,
      parameterValues: parameterValues,
      resultFormatCodes: [1],
      flush: false,
    );
    await _frontendMessages!.writeExecute(flush: false);
    await _frontendMessages!.writeSync();

    final fields = rowDescription.fields;
    final handlers = List<TypeHandler?>.filled(fields.length, null);
    final oids = List<int>.filled(fields.length, 0);
    for (var i = 0; i < fields.length; i++) {
      final oid = fields[i].oid;
      oids[i] = oid;
      handlers[i] = _typeRegistry.resolve(oid);
    }

    final rows = <List<Object?>>[];
    while (true) {
      final msg = await readMessage();
      if (msg is BindCompleteMessage ||
          msg is ParseCompleteMessage ||
          msg is CloseCompletedMessage ||
          msg is ParameterDescriptionMessage ||
          msg is NoDataMessage) {
        continue;
      }
      if (msg is DataRowMessage) {
        rows.add(_decodeMaterializedRow(msg, oids, handlers));
        continue;
      }
      if (msg is CommandCompleteMessage) {
        continue;
      }
      if (msg is ReadyForQueryMessage) {
        return rows;
      }
      if (msg is ErrorResponseMessage) {
        final err = msg.error;
        throw PostgresException(
          severity: err.severity ?? 'ERROR',
          invariantSeverity: err.invariantSeverity ?? err.severity ?? 'ERROR',
          sqlState: err.sqlState ?? '00000',
          messageText: err.messageText ?? 'Unknown Error',
          detail: err.detail,
          hint: err.hint,
        );
      }
      if (msg is RowDescriptionMessage) {
        continue;
      }
    }
  }

  List<Object?> _decodeMaterializedRow(
    DataRowMessage row,
    List<int> oids,
    List<TypeHandler?> handlers,
  ) {
    final values = List<Object?>.filled(row.columnCount, null);
    for (var i = 0; i < row.columnCount; i++) {
      values[i] = _decodeMaterializedValue(row, i, oids, handlers);
    }
    return values;
  }

  Map<String, dynamic> _decodeMaterializedMap(
    DataRowMessage row,
    List<String> columnNames,
    List<int> oids,
    List<TypeHandler?> handlers,
  ) {
    final map = <String, dynamic>{};
    for (var i = 0; i < row.columnCount; i++) {
      map[columnNames[i]] = _decodeMaterializedValue(row, i, oids, handlers);
    }
    return map;
  }

  Map<String, dynamic> _decodeMaterializedRawTextMap(
    DataRowMessage row,
    List<String> columnNames,
  ) {
    final map = <String, dynamic>{};
    for (var i = 0; i < row.columnCount; i++) {
      final length = row.columnLengths[i];
      if (length == -1) {
        map[columnNames[i]] = null;
        continue;
      }
      map[columnNames[i]] =
          _decodeText(row.payload, row.columnOffsets[i], length);
    }
    return map;
  }

  Object? _decodeMaterializedValue(
    DataRowMessage row,
    int index,
    List<int> oids,
    List<TypeHandler?> handlers,
  ) {
    final length = row.columnLengths[index];
    if (length == -1) {
      return null;
    }

    final payload = row.payload;
    final offset = row.columnOffsets[index];
    final oid = oids[index];
    switch (oid) {
      case Oid.int2:
        if (length == 2) {
          return _readInt16(payload, offset);
        }
        break;
      case Oid.int4:
        if (length == 4) {
          return _readInt32(payload, offset);
        }
        break;
      case Oid.int8:
        if (length == 8) {
          return _readInt64(payload, offset);
        }
        break;
      case Oid.text:
      case Oid.varchar:
      case Oid.bpchar:
      case Oid.unknown:
        return _decodeText(payload, offset, length);
      case Oid.bool:
        return length > 0 && payload[offset] != 0;
      case Oid.date:
        if (length == 4) {
          return TimezoneHelper.decodeDate(
            _readInt32(payload, offset),
            timeZone: timeZone,
          );
        }
        break;
      case Oid.float4:
        if (length == 4) {
          return ByteData.view(
            payload.buffer,
            payload.offsetInBytes + offset,
            4,
          ).getFloat32(0);
        }
        break;
      case Oid.float8:
        if (length == 8) {
          return ByteData.view(
            payload.buffer,
            payload.offsetInBytes + offset,
            8,
          ).getFloat64(0);
        }
        break;
      case Oid.timestamp:
        if (length == 8) {
          return TimezoneHelper.decodeTimestamp(
            _readInt64(payload, offset),
            timeZone: timeZone,
          );
        }
        break;
      case Oid.timestamptz:
        if (length == 8) {
          return TimezoneHelper.decodeTimestampTz(
            _readInt64(payload, offset),
            timeZone: timeZone,
          );
        }
        break;
      case Oid.numeric:
        if (length >= 8 && handlers[index] is TypeHandler<double>) {
          return _readNumericDouble(payload, offset, length);
        }
        break;
    }

    final colData = Uint8List.sublistView(payload, offset, offset + length);
    return handlers[index]?.read(colData, isText: false) ?? colData;
  }

  String _decodeText(Uint8List payload, int offset, int length) {
    if (identical(encoding, utf8)) {
      final end = offset + length;
      var asciiOnly = true;
      for (var i = offset; i < end; i++) {
        if (payload[i] >= 0x80) {
          asciiOnly = false;
          break;
        }
      }
      if (asciiOnly) {
        return String.fromCharCodes(payload, offset, end);
      }
      return utf8.decoder.convert(payload, offset, offset + length);
    }
    return encoding
        .decode(Uint8List.sublistView(payload, offset, offset + length));
  }

  int _readInt16(Uint8List payload, int offset) {
    final value = (payload[offset] << 8) | payload[offset + 1];
    return value.toSigned(16);
  }

  int _readInt32(Uint8List payload, int offset) {
    final value = (payload[offset] << 24) |
        (payload[offset + 1] << 16) |
        (payload[offset + 2] << 8) |
        payload[offset + 3];
    return value.toSigned(32);
  }

  int _readUint32(Uint8List payload, int offset) {
    return (payload[offset] << 24) |
        (payload[offset + 1] << 16) |
        (payload[offset + 2] << 8) |
        payload[offset + 3];
  }

  int _readInt64(Uint8List payload, int offset) {
    final high = _readInt32(payload, offset);
    final low = _readUint32(payload, offset + 4);
    return (high << 32) | low;
  }

  double _readNumericDouble(Uint8List payload, int offset, int length) {
    final end = offset + length;
    if (offset + 8 > end) {
      throw FormatException('Invalid numeric length: $length');
    }

    final ndigits = _readInt16(payload, offset);
    offset += 2;
    final weight = _readInt16(payload, offset);
    offset += 2;
    final sign = _readInt16(payload, offset);
    offset += 2;
    offset += 2;

    if (sign == 0xC000) {
      return double.nan;
    }
    if (ndigits == 0) {
      return sign == 0x4000 ? -0.0 : 0.0;
    }

    var value = 0.0;
    for (var i = 0; i < ndigits; i++) {
      if (offset + 2 > end) {
        throw FormatException('Invalid numeric digit length: $length');
      }
      value = (value * 10000) + _readInt16(payload, offset);
      offset += 2;
    }

    var scaleGroups = ndigits - weight - 1;
    while (scaleGroups > 0) {
      value /= 10000;
      scaleGroups--;
    }
    while (scaleGroups < 0) {
      value *= 10000;
      scaleGroups++;
    }

    return sign == 0x4000 ? -value : value;
  }

  Future<void> _writePendingUnprepareMessages() async {
    final pending = preparedStatementManager.takePendingUnprepare();
    for (final statement in pending) {
      final name = statement.name;
      if (name == null || name.isEmpty) {
        continue;
      }
      await _frontendMessages!.writeCloseStatement(name, flush: false);
    }
  }

  Future<DpgsqlDataReader> executeBatch(DpgsqlBatch batch) async {
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
        cmd.commandTag = null;
        cmd.recordsAffected = 0;
        cmd.exception = null;

        String sqlToExecute = cmd.commandText;
        DpgsqlParameterCollection paramsToUse = cmd.parameters;

        if (cmd.parameters.isNotEmpty) {
          final rewritten =
              SqlRewriter.rewrite(cmd.commandText, cmd.parameters);
          sqlToExecute = rewritten.sql;
          paramsToUse = DpgsqlParameterCollection();
          paramsToUse.addAll(rewritten.orderedParameters);
        }

        final pending = await executeQueryPipelined(
          sql: sqlToExecute,
          parameters: paramsToUse,
        );
        pending.batchCommand = cmd;
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
    return createPipelineReader(
      pendingCommands,
      batchCommands: batch.batchCommands,
    );
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
    DpgsqlParameterCollection? parameters,
    PgResultMode resultMode = PgResultMode.typed,
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
      resultMode: resultMode,
    );

    _pipelineQueue!.enqueue(pendingCmd);

    // Send Parse, Bind, Execute without forcing a flush
    await _sendQueryMessages(
      sql: sql,
      statementName: statementName,
      parameters: parameters,
      resultMode: resultMode,
    );

    final writer = _msgWriter;
    if (writer != null) {
      final buffer = writer.buffer;
      if (buffer != null &&
          (buffer.bufferedBytes >= buffer.maxBufferSize ||
              buffer.messageCount >= 16)) {
        await buffer.flush();
      }
    }

    return pendingCmd;
  }

  /// Send Parse/Bind/Execute messages without triggering an immediate flush.
  /// This is used for pipeline mode.
  Future<void> _sendQueryMessages({
    required String sql,
    String? statementName,
    DpgsqlParameterCollection? parameters,
    PgResultMode resultMode = PgResultMode.typed,
  }) async {
    final params = parameters ?? DpgsqlParameterCollection();

    // Collect parameter OIDs and values
    final paramOids = <int>[];
    final paramValues = <dynamic>[];
    final paramHandlers = <TypeHandler?>[];

    for (final p in params) {
      TypeHandler? handler;
      if (p.dpgsqlDbType != null) {
        handler = _typeRegistry.resolveByDpgsqlDbType(p.dpgsqlDbType!);
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
      resultFormatCodes: [resultMode == PgResultMode.rawText ? 0 : 1],
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
