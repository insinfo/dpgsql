import 'dart:async';
import 'dart:collection';
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
import '../types/custom_type_handlers.dart';
import '../types/type_handler.dart';
import '../dpgsql_batch.dart';
import '../dpgsql_batch_command.dart';
import '../dpgsql_db_type.dart';
import '../dpgsql_parameter.dart';
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
    bool decodeNetworkTypesAsString = true,
    bool decodeUuidAsString = true,
    bool decodeJsonAsString = false,
    bool decodeNumericAsString = false,
    bool useCustomDecimal = false,
    bool decodeExtendedTypesAsText = false,
    this.inferStringParametersAsUnknown = true,
    this.useExtendedQueryForUnparameterizedCommands = false,
  })  : timeZone = timeZone ?? const TimeZoneSettings.utc(),
        preparedStatementManager = PreparedStatementManager(
          maxAutoPrepared: maxAutoPrepare,
          usagesBeforeAutoPrepare: autoPrepareMinUsages,
        ),
        _typeRegistry = TypeHandlerRegistry(
          timeZone: timeZone ?? const TimeZoneSettings.utc(),
          decodeNetworkTypesAsString: decodeNetworkTypesAsString,
          decodeUuidAsString: decodeUuidAsString,
          decodeJsonAsString: decodeJsonAsString,
          decodeNumericAsString: decodeNumericAsString,
          useCustomDecimal: useCustomDecimal,
          decodeExtendedTypesAsText: decodeExtendedTypesAsText,
        );

  final String host;
  final int port;
  final String username;
  final String password;
  final String database;
  final SslMode sslMode;
  final bool trustServerCertificate;

  /// Whether [sslMode] requires a verified server certificate.
  bool get _verifiesCertificate =>
      sslMode == SslMode.verifyCa || sslMode == SslMode.verifyFull;
  final Encoding encoding;
  final String? clientEncoding;
  final TimeZoneSettings timeZone;
  final bool replication;
  final bool inferStringParametersAsUnknown;
  final bool useExtendedQueryForUnparameterizedCommands;
  final PreparedStatementManager preparedStatementManager;

  Socket? _socket;
  SocketBinaryInput? _readBuffer;
  SocketBinaryOutput? _writeBuffer;

  PostgresMessageReader? _msgReader;
  PostgresMessageWriter? _msgWriter;

  final TypeHandlerRegistry _typeRegistry;
  final Map<String, RowDescriptionMessage> _preparedRowDescriptions = {};

  /// Result columns of the statements auto-prepared in the same round trip as
  /// their first execution, used only to choose the result formats of the
  /// next executions ([_resultFormatCodes]). Without it every later
  /// execution of a parameterized query asked for text results.
  final Map<String, RowDescriptionMessage> _autoPreparedColumns = {};
  final Map<String, _PreparedMapMetadata> _preparedMapMetadata = {};
  final Queue<IBackendMessage> _bufferedBackendMessages =
      Queue<IBackendMessage>();

  FrontendMessages? _frontendMessages;
  late BackendMessageReader _backendReader;
  ScramSha256Authenticator? _scram;

  bool _isConnected = false;
  bool get isConnected => _isConnected;

  /// Called when bytes arrive from the server (set by DpgsqlConnection to
  /// deliver notifications while no command is running).
  void Function()? onDataArrived;

  /// Called when the server closes the socket while connected.
  void Function()? onConnectionLost;
  Map<String, String> _serverParameters = {};
  int _backendProcessId = 0;
  int _backendSecretKey = 0;

  TypeHandlerRegistry get typeRegistry => _typeRegistry;

  TypeHandler? _resolveParameterHandler(DpgsqlParameter parameter) {
    final value = parameter.value;
    if (value == null) {
      return null;
    }

    final dbType = parameter.dpgsqlDbType;
    if (dbType != null) {
      if (dbType == DpgsqlDbType.unknown) {
        return null;
      }
      return _typeRegistry.resolveByDpgsqlDbType(dbType);
    }

    if (inferStringParametersAsUnknown &&
        (value is String || _isStringList(value))) {
      // Sent as `unknown` text (a `{...}` array literal for lists), so the
      // server infers uuid, inet, date, varchar[] ... from the context, e.g.
      // `uuid_col = any(?)`. A typed text[] made that fail with
      // "operator does not exist: uuid = text".
      return null;
    }

    return _typeRegistry.resolveByValue(value);
  }

  /// A non-empty list holding only strings and nulls (nested lists allowed).
  static bool _isStringList(Object value) {
    if (value is! List || value.isEmpty) return false;
    var sawString = false;
    bool check(List items) {
      for (final item in items) {
        if (item == null) continue;
        if (item is String) {
          sawString = true;
        } else if (item is List) {
          if (!check(item)) return false;
        } else {
          return false;
        }
      }
      return true;
    }

    return check(value) && sawString;
  }

  /// Text form of a parameter sent without a type handler (OID 0).
  static String _textParameter(Object value) {
    // Maps (and lists of maps) are JSON; `toString()` produced `{a: 1}`,
    // which json/jsonb reject.
    if (value is Map ||
        (value is List && value.isNotEmpty && value.every((e) => e is Map))) {
      return json.encode(value);
    }
    if (value is List) return _arrayLiteral(value);
    return value.toString();
  }

  /// PostgreSQL array literal: `{"a","b\"c",NULL,{"x"}}`.
  static String _arrayLiteral(List items) {
    final buffer = StringBuffer('{');
    for (var i = 0; i < items.length; i++) {
      if (i > 0) buffer.write(',');
      final item = items[i];
      if (item == null) {
        buffer.write('NULL');
      } else if (item is List) {
        buffer.write(_arrayLiteral(item));
      } else {
        final text =
            item.toString().replaceAll(r'\', r'\\').replaceAll('"', r'\"');
        buffer
          ..write('"')
          ..write(text)
          ..write('"');
      }
    }
    buffer.write('}');
    return buffer.toString();
  }

  int _parameterOid(TypeHandler? handler) => handler?.oid ?? 0;

  void _encodeParameter(
    DpgsqlParameter parameter,
    TypeHandler? handler,
    List<Uint8List?> values,
    List<int> formatCodes,
  ) {
    final value = parameter.value;
    if (value == null) {
      values.add(null);
      formatCodes.add(0);
      return;
    }

    if (handler != null) {
      values.add(handler.write(value));
      formatCodes.add(1);
      return;
    }

    values.add(Uint8List.fromList(encoding.encode(_textParameter(value))));
    formatCodes.add(0);
  }

  void _encodeParameters(
    DpgsqlParameterCollection parameters,
    List<Uint8List?> values,
    List<int> formatCodes,
  ) {
    for (final parameter in parameters) {
      _encodeParameter(
        parameter,
        _resolveParameterHandler(parameter),
        values,
        formatCodes,
      );
    }
  }

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
            // Called when the certificate failed the system CA (and host
            // name) validation. VerifyCA and VerifyFull exist to verify it:
            // Trust Server Certificate (true by default in the connection
            // string) applies only to the other modes, as in libpq/Npgsql.
            onBadCertificate: (cert) =>
                !_verifiesCertificate && trustServerCertificate,
          );
          // Update inputStream to the new SecureSocket
          inputStream = _socket!;
        } else if (response == 78) {
          // 'N': only Allow and Prefer may go on in plain text.
          if (sslMode == SslMode.require || _verifiesCertificate) {
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
      _readBuffer = SocketBinaryInput(
        inputStream,
        onClosed: () {
          final wasConnected = _isConnected;
          _isConnected = false;
          if (wasConnected) onConnectionLost?.call();
        },
        onData: () => onDataArrived?.call(),
      );
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
    final socket = _socket;
    if (socket != null) {
      _socket = null;
      // Errors of a socket being closed are irrelevant (they used to surface
      // as uncaught errors after the server had closed the connection).
      socket.done.catchError((_) => socket);
      if (_isConnected) {
        try {
          await _frontendMessages?.writeTerminate();
        } catch (_) {
          // Ignore errors during termination
        }
        try {
          await socket.close();
        } catch (_) {}
      } else {
        // The server already closed it: writing Terminate would fail.
        socket.destroy();
      }
    }
    _readBuffer?.dispose();
    _readBuffer = null;
    _isConnected = false;
  }

  Future<void> cancelRequest() async {
    if (_backendProcessId == 0 || _backendSecretKey == 0) return;

    Socket? socket;
    try {
      socket = await Socket.connect(host, port);
      final buffer = SocketBinaryOutput(socket);
      final writer = PostgresMessageWriter(buffer);
      final frontend = FrontendMessages(writer);

      await frontend.writeCancelRequest(_backendProcessId, _backendSecretKey);
      await socket.flush();
      await socket.close();
      // The server closes the connection once it has read the request. The
      // read side was never consumed, so the socket stayed open, and kept the
      // process from exiting, after cancel(). Not awaited: cancel() returns
      // once the request is sent, before the cancelled command fails.
      final sent = socket;
      socket = null;
      unawaited(sent
          .drain<void>()
          .timeout(const Duration(seconds: 5), onTimeout: () {})
          .catchError((_) {})
          .whenComplete(sent.destroy));
    } catch (e) {
      // Ignore errors during cancel
    } finally {
      socket?.destroy();
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
      final msg = _bufferedBackendMessages.isNotEmpty
          ? _bufferedBackendMessages.removeFirst()
          : await _readRawMessageAndDrainAvailable();

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

  /// Delivers the notifications, notices and parameter changes already
  /// received while no command is running. Synchronous: only complete
  /// messages in the buffer are read; any other message is kept for the next
  /// reader.
  void drainAsyncMessages() {
    if (!_isConnected || _msgReader == null || inPipelineMode) return;
    while (_bufferedBackendMessages.isNotEmpty) {
      if (!_dispatchAsyncMessage(_bufferedBackendMessages.first)) return;
      _bufferedBackendMessages.removeFirst();
    }
    while (true) {
      final raw = _msgReader!.tryReadMessage();
      if (raw == null) return;
      final msg = _backendReader.parse(raw);
      if (!_dispatchAsyncMessage(msg)) {
        _bufferedBackendMessages.add(msg);
        return;
      }
    }
  }

  bool _dispatchAsyncMessage(IBackendMessage msg) {
    if (msg is NotificationResponseMessage) {
      _notificationController.add(
          DpgsqlNotificationEventArgs(msg.channel, msg.payload, msg.processId));
      return true;
    }
    if (msg is NoticeResponseMessage) {
      _noticeController.add(msg.notice);
      return true;
    }
    if (msg is ParameterStatusMessage) {
      _serverParameters[msg.parameter] = msg.value;
      return true;
    }
    return false;
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

  /// Throws the error in [msg]. Outside pipeline mode the rest of the
  /// response is consumed first: PostgreSQL ends an errored simple query or
  /// Sync with ReadyForQuery, and leaving it unread made the next command
  /// finish on it, so every later command returned the previous one's result.
  Future<Never> _throwAfterReadyForQuery(ErrorResponseMessage msg) async {
    final err = msg.error;
    final exception = PostgresException(
      severity: err.severity ?? 'ERROR',
      invariantSeverity: err.invariantSeverity ?? err.severity ?? 'ERROR',
      sqlState: err.sqlState ?? '00000',
      messageText: err.messageText ?? 'Unknown Error',
      detail: err.detail,
      hint: err.hint,
    );
    if (!inPipelineMode) {
      while (true) {
        final next = await _readMessage();
        if (next is ReadyForQueryMessage) break;
      }
    }
    throw exception;
  }

  /// Rethrows [error] (a value that failed to decode, or a row callback
  /// that threw) after consuming the rest of the response, like
  /// [_throwAfterReadyForQuery]: leaving it unread made every later command
  /// return the previous command's result.
  Future<Never> _drainAndRethrow(Object error, StackTrace stackTrace) async {
    if (!inPipelineMode) {
      while (true) {
        final next = await _readMessage();
        if (next is ReadyForQueryMessage) break;
      }
    }
    Error.throwWithStackTrace(error, stackTrace);
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

  Future<IBackendMessage> _readRawMessageAndDrainAvailable() async {
    final raw = await _msgReader!.readMessage();
    final first = _backendReader.parse(raw);

    while (true) {
      final next = _msgReader!.tryReadMessage();
      if (next == null) {
        break;
      }
      _bufferedBackendMessages.add(_backendReader.parse(next));
    }

    return first;
  }

  Future<void> prepare(String sql, String statementName,
      DpgsqlParameterCollection parameters) async {
    // 1. Parse (Prepare)
    final paramOids = <int>[];
    for (final p in parameters) {
      paramOids.add(_parameterOid(_resolveParameterHandler(p)));
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
        _preparedMapMetadata.remove(statementName);
        continue;
      }
      if (msg is NoDataMessage) continue;
      if (msg is ReadyForQueryMessage) break;
      if (msg is ErrorResponseMessage) {
        await _throwAfterReadyForQuery(msg);
      }
    }
  }

  /// Result format codes for a statement whose columns are [description]:
  /// binary for the columns with a binary decoder, text for the others
  /// (enums, tsvector, reg*, user-defined types). Their binary form is not
  /// decoded: an enum came back as bytes, indistinguishable from bytea. Text
  /// for every column when the columns are not known yet (the statement is
  /// parsed in the same round trip), as the simple protocol does.
  List<int> _resultFormatCodes(
      RowDescriptionMessage? description, PgResultMode resultMode) {
    if (resultMode == PgResultMode.rawText || description == null) {
      return const [0];
    }
    final codes = [
      for (final field in description.fields)
        _typeRegistry.resolve(field.oid) != null ? 1 : 0,
    ];
    if (codes.every((code) => code == 1)) return const [1];
    if (codes.every((code) => code == 0)) return const [0];
    return codes;
  }

  /// Every column of [description] has a binary decoder: the prepared fast
  /// paths, which request binary results, can read it.
  bool _binaryDecodable(RowDescriptionMessage description) => description.fields
      .every((field) => _typeRegistry.resolve(field.oid) != null);

  /// [extendedQuery]: use the extended protocol even without parameters.
  /// [binaryResults]: every column in binary (PgRow reads binary values);
  /// otherwise see [_resultFormatCodes].
  Future<DpgsqlDataReader> executeReader(String sql,
      {DpgsqlParameterCollection? parameters,
      String? statementName,
      bool rewriteParameters = true,
      PgResultMode resultMode = PgResultMode.typed,
      bool extendedQuery = false,
      bool binaryResults = false,
      bool simpleQuery = false}) async {
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
        paramHandlers.add(_resolveParameterHandler(p));
      }

      final paramOids = <int>[];
      for (final handler in paramHandlers) {
        paramOids.add(_parameterOid(handler));
      }

      // Encoded before anything is written: a value that failed to encode
      // (a Map holding a non-JSON value, an out-of-range int) used to leave
      // Parse in the write buffer, sent ahead of the next command; when that
      // Parse failed, the server skipped the next command up to its Sync and
      // the connection hung.
      final values = <Uint8List?>[];
      final formatCodes = <int>[];
      for (var i = 0; i < paramsToUse.length; i++) {
        _encodeParameter(paramsToUse[i], paramHandlers[i], values, formatCodes);
      }

      var statementNameToUse = statementName;
      PreparedStatement? autoPrepareStatement;
      PreparedStatement? autoPrepared;

      if (statementName == null) {
        if (preparedStatementManager.maxAutoPrepared > 0) {
          final prepared = preparedStatementManager.tryGetPreparedStatement(
            sqlToExecute,
            paramOids,
          );
          if (prepared != null) {
            statementNameToUse = prepared.name;
            autoPrepared = prepared;
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

      // 2. Bind. The columns are known for a statement prepared earlier, not
      // for one parsed in this round trip.
      final description =
          autoPrepareStatement == null && statementNameToUse != null
              ? _preparedRowDescriptions[statementNameToUse] ??
                  _autoPreparedColumns[statementNameToUse]
              : null;
      await _frontendMessages!.writeBind(
        portalName: '',
        statementName: statementNameToUse ?? '',
        parameterValues: values,
        parameterFormatCodes: formatCodes,
        resultFormatCodes: binaryResults
            ? const [1]
            : _resultFormatCodes(description, resultMode),
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
          final name = autoPrepareStatement.name;
          final columns = reader.rowDescriptionMessage;
          if (name != null && columns != null) {
            _autoPreparedColumns[name] = columns;
          }
        }
      } catch (error) {
        if (autoPrepareStatement != null) {
          autoPrepareStatement.abortPrepare();
        }
        _invalidateAutoPrepared(autoPrepared, error);
        rethrow;
      }
      return reader;
    } else {
      // Simple Query Protocol is the default when there are no parameters,
      // preserving PostgreSQL multi-statement semantics. Some ORM workloads
      // prefer extended protocol even without parameters to request binary
      // result columns and avoid text parsing on every row.
      // [simpleQuery]: several statements in one round trip (the pool's
      // reset), even with useExtendedQueryForUnparameterizedCommands.
      if (statementName != null ||
          extendedQuery ||
          (useExtendedQueryForUnparameterizedCommands && !simpleQuery)) {
        // Extended Protocol without parameters
        if (statementName == null) {
          await _frontendMessages!.writeParse(
            query: sql,
            parameterTypeOids: const <int>[],
            flush: false,
          );
        }
        await _frontendMessages!.writeBind(
          portalName: '',
          statementName: statementName ?? '',
          resultFormatCodes: binaryResults
              ? const [1]
              : _resultFormatCodes(
                  statementName == null
                      ? null
                      : _preparedRowDescriptions[statementName],
                  resultMode),
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
    if (preparedDescription != null && _binaryDecodable(preparedDescription)) {
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

  Future<Object?> executeScalar(
    String sql, {
    DpgsqlParameterCollection? parameters,
    String? statementName,
    bool rewriteParameters = true,
  }) async {
    final preparedDescription =
        statementName == null ? null : _preparedRowDescriptions[statementName];
    if (preparedDescription != null && _binaryDecodable(preparedDescription)) {
      return _executePreparedScalarFast(
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
      // The first value of the first row, reading the whole response like
      // the prepared path: close() drops errors, so an error raised after the
      // first row (`select 1 / (g - 2) ...`) or by a later statement used to
      // be lost, returning a value of a failed statement. As in executeMaps,
      // statements without rows before the query (`set ...; select ...`) are
      // skipped.
      Object? value;
      var found = false;
      do {
        while (await reader.read()) {
          if (!found && reader.fieldCount > 0) {
            value = reader.getValue(0);
            found = true;
          }
        }
      } while (await reader.nextResult());
      return value;
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
    if (preparedDescription != null &&
        (resultMode == PgResultMode.rawText ||
            _binaryDecodable(preparedDescription))) {
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

    final autoPreparedRows = await _tryExecuteAutoPreparedUnparameterizedMaps(
      sql,
      parameters: parameters,
      statementName: statementName,
      resultMode: resultMode,
    );
    if (autoPreparedRows != null) {
      return autoPreparedRows;
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

  Future<List<Map<String, dynamic>>?>
      _tryExecuteAutoPreparedUnparameterizedMaps(
    String sql, {
    DpgsqlParameterCollection? parameters,
    String? statementName,
    required PgResultMode resultMode,
  }) async {
    if (!useExtendedQueryForUnparameterizedCommands ||
        statementName != null ||
        (parameters != null && parameters.isNotEmpty) ||
        preparedStatementManager.maxAutoPrepared <= 0) {
      return null;
    }

    const paramOids = <int>[];
    final prepared = preparedStatementManager.tryGetPreparedStatement(
      sql,
      paramOids,
    );
    final preparedName = prepared?.name;
    final preparedDescription =
        preparedName == null ? null : _preparedRowDescriptions[preparedName];
    if (preparedName != null &&
        (preparedDescription == null ||
            (resultMode != PgResultMode.rawText &&
                !_binaryDecodable(preparedDescription)))) {
      // A statement without rows (NoData): it is run by name. The unnamed
      // path made the next call prepare it again: "prepared statement _pN
      // already exists" (42P05). Columns without a binary decoder are read
      // in text by the reader, not by the binary fast path.
      return _executeNamedMaps(sql, prepared!, resultMode);
    }
    if (preparedName != null && preparedDescription != null) {
      try {
        return await (resultMode == PgResultMode.rawText
            ? _executePreparedMapsRawTextFast(
                preparedName,
                parameters,
                preparedDescription,
              )
            : _executePreparedMapsFast(
                preparedName,
                parameters,
                preparedDescription,
              ));
      } catch (error) {
        _invalidateAutoPrepared(prepared, error);
        rethrow;
      }
    }

    final candidate =
        preparedStatementManager.tryGetOrCreateAutoPrepareCandidate(
      sql,
      paramOids,
    );
    if (candidate == null) {
      return null;
    }

    final autoPrepareStatement = preparedStatementManager.beginAutoPrepare(
      candidate,
      paramOids,
    );
    final autoPreparedName = autoPrepareStatement?.name;
    if (autoPrepareStatement == null ||
        autoPreparedName == null ||
        autoPreparedName.isEmpty) {
      return null;
    }

    try {
      await _writePendingUnprepareMessages();
      await prepare(sql, autoPreparedName, DpgsqlParameterCollection());
      preparedStatementManager.completeAutoPrepare(autoPrepareStatement);
    } catch (_) {
      autoPrepareStatement.abortPrepare();
      rethrow;
    }

    final rowDescription = _preparedRowDescriptions[autoPreparedName];
    if (rowDescription == null ||
        (resultMode != PgResultMode.rawText &&
            !_binaryDecodable(rowDescription))) {
      return _executeNamedMaps(sql, autoPrepareStatement, resultMode);
    }

    return resultMode == PgResultMode.rawText
        ? _executePreparedMapsRawTextFast(
            autoPreparedName,
            parameters,
            rowDescription,
          )
        : _executePreparedMapsFast(
            autoPreparedName,
            parameters,
            rowDescription,
          );
  }

  Future<List<Map<String, dynamic>>> _executeNamedMaps(
    String sql,
    PreparedStatement statement,
    PgResultMode resultMode,
  ) async {
    try {
      final reader = await executeReader(
        sql,
        statementName: statement.name,
        resultMode: resultMode,
      );
      return await (reader as DpgsqlDataReaderImpl).readAllMaps();
    } catch (error) {
      _invalidateAutoPrepared(statement, error);
      rethrow;
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

    // PgRow reads binary values. Rows used to be rebuilt from the decoded
    // values' text, named column_0, column_1, ...: getInt/getDouble/
    // getDateTime threw and getByName did not find the columns.
    final reader = await executeReader(
      sql,
      parameters: parameters,
      statementName: statementName,
      rewriteParameters: rewriteParameters,
      extendedQuery: true,
      binaryResults: true,
    );
    try {
      return await (reader as DpgsqlDataReaderImpl).readAllPgRows();
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

    _encodeParameters(params, parameterValues, parameterFormatCodes);

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

    final metadata = _preparedMapMetadataFor(statementName, rowDescription);

    if ((_pipelineQueue == null || !_pipelineQueue!.inPipelineMode) &&
        _bufferedBackendMessages.isEmpty) {
      return _readPreparedMapsFastRaw(metadata);
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
        try {
          rows.add(_decodeMaterializedMap(
            msg,
            metadata.columnNames,
            metadata.oids,
            metadata.handlers,
          ));
        } catch (error, stackTrace) {
          await _drainAndRethrow(error, stackTrace);
        }
        continue;
      }
      if (msg is CommandCompleteMessage || msg is RowDescriptionMessage) {
        continue;
      }
      if (msg is ReadyForQueryMessage) {
        return rows;
      }
      if (msg is ErrorResponseMessage) {
        await _throwAfterReadyForQuery(msg);
      }
    }
  }

  Future<List<Map<String, dynamic>>> _readPreparedMapsFastRaw(
    _PreparedMapMetadata metadata,
  ) async {
    final rows = <Map<String, dynamic>>[];
    final rawQueue = Queue<PostgresMessage>();

    Future<PostgresMessage> nextRawMessage() async {
      if (rawQueue.isNotEmpty) {
        return rawQueue.removeFirst();
      }
      final first = await _msgReader!.readMessage();
      while (true) {
        final next = _msgReader!.tryReadMessage();
        if (next == null) {
          break;
        }
        rawQueue.add(next);
      }
      return first;
    }

    // Messages read past ReadyForQuery (a notification) belong to the
    // connection, not to this command: they used to be dropped.
    void keepRest() {
      while (rawQueue.isNotEmpty) {
        _bufferedBackendMessages
            .add(_backendReader.parse(rawQueue.removeFirst()));
      }
    }

    // Consumes the response up to ReadyForQuery, then throws [error]. An
    // ErrorResponse used to be thrown with ReadyForQuery unread, so the next
    // command returned this one's leftovers.
    Future<Never> drainAndThrow(Object error, StackTrace stackTrace) async {
      while (true) {
        final raw = await nextRawMessage();
        if (raw.typeCode == 0x5A) {
          _handleReadyForQueryMessage();
          break;
        }
        if (raw.typeCode == 0x41 ||
            raw.typeCode == 0x4E ||
            raw.typeCode == 0x53) {
          _dispatchAsyncMessage(_backendReader.parse(raw));
        }
      }
      keepRest();
      Error.throwWithStackTrace(error, stackTrace);
    }

    while (true) {
      final raw = await nextRawMessage();
      switch (raw.typeCode) {
        case 0x44: // DataRow
          final row = _backendReader.parse(raw) as DataRowMessage;
          try {
            rows.add(_decodeMaterializedMap(
              row,
              metadata.columnNames,
              metadata.oids,
              metadata.handlers,
            ));
          } catch (error, stackTrace) {
            await drainAndThrow(error, stackTrace);
          }
          continue;
        case 0x5A: // ReadyForQuery
          _handleReadyForQueryMessage();
          keepRest();
          return rows;
        case 0x43: // CommandComplete
        case 0x54: // RowDescription
        case 0x32: // BindComplete
        case 0x31: // ParseComplete
        case 0x33: // CloseComplete
        case 0x74: // ParameterDescription
        case 0x6E: // NoData
          continue;
        case 0x41: // NotificationResponse
          final msg = _backendReader.parse(raw) as NotificationResponseMessage;
          _notificationController.add(DpgsqlNotificationEventArgs(
            msg.channel,
            msg.payload,
            msg.processId,
          ));
          continue;
        case 0x4E: // NoticeResponse
          final msg = _backendReader.parse(raw) as NoticeResponseMessage;
          _noticeController.add(msg.notice);
          continue;
        case 0x53: // ParameterStatus
          final msg = _backendReader.parse(raw) as ParameterStatusMessage;
          _serverParameters[msg.parameter] = msg.value;
          continue;
        case 0x45: // ErrorResponse
          final msg = _backendReader.parse(raw) as ErrorResponseMessage;
          final err = msg.error;
          await drainAndThrow(
            PostgresException(
              severity: err.severity ?? 'ERROR',
              invariantSeverity:
                  err.invariantSeverity ?? err.severity ?? 'ERROR',
              sqlState: err.sqlState ?? '00000',
              messageText: err.messageText ?? 'Unknown Error',
              detail: err.detail,
              hint: err.hint,
            ),
            StackTrace.current,
          );
        default:
          _bufferedBackendMessages.add(_backendReader.parse(raw));
          keepRest();
          final msg = await readMessage();
          if (msg is ReadyForQueryMessage) {
            return rows;
          }
          if (msg is ErrorResponseMessage) {
            await _throwAfterReadyForQuery(msg);
          }
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

    _encodeParameters(params, parameterValues, parameterFormatCodes);

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

    final columnNames =
        _preparedMapMetadataFor(statementName, rowDescription).columnNames;

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
        try {
          rows.add(_decodeMaterializedRawTextMap(msg, columnNames));
        } catch (error, stackTrace) {
          await _drainAndRethrow(error, stackTrace);
        }
        continue;
      }
      if (msg is ReadyForQueryMessage) {
        return rows;
      }
      if (msg is ErrorResponseMessage) {
        await _throwAfterReadyForQuery(msg);
      }
    }
  }

  _PreparedMapMetadata _preparedMapMetadataFor(
    String statementName,
    RowDescriptionMessage rowDescription,
  ) {
    final cached = _preparedMapMetadata[statementName];
    if (cached != null) {
      return cached;
    }

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

    final metadata = _PreparedMapMetadata(columnNames, oids, handlers);
    _preparedMapMetadata[statementName] = metadata;
    return metadata;
  }

  Future<List<PgRow>> _executePreparedPgRowsFast(
    String statementName,
    DpgsqlParameterCollection? parameters,
    RowDescriptionMessage rowDescription,
  ) async {
    final params = parameters ?? DpgsqlParameterCollection();
    final parameterValues = <Uint8List?>[];
    final parameterFormatCodes = <int>[];

    _encodeParameters(params, parameterValues, parameterFormatCodes);

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
        await _throwAfterReadyForQuery(msg);
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

    _encodeParameters(params, parameterValues, parameterFormatCodes);

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
        try {
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
        } catch (error, stackTrace) {
          await _drainAndRethrow(error, stackTrace);
        }
        continue;
      }
      if (msg is ReadyForQueryMessage) {
        return;
      }
      if (msg is ErrorResponseMessage) {
        await _throwAfterReadyForQuery(msg);
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

    _encodeParameters(params, parameterValues, parameterFormatCodes);

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
        try {
          action(PgRow(
            buffer: msg.payload,
            columnOffsets: msg.columnOffsets,
            columnLengths: msg.columnLengths,
            columnNames: columnNames,
            columnTypes: columnTypes,
            timeZone: timeZone,
          ));
        } catch (error, stackTrace) {
          await _drainAndRethrow(error, stackTrace);
        }
        continue;
      }
      if (msg is ReadyForQueryMessage) {
        return;
      }
      if (msg is ErrorResponseMessage) {
        await _throwAfterReadyForQuery(msg);
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

    _encodeParameters(params, parameterValues, parameterFormatCodes);

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
        try {
          rows.add(_decodeMaterializedRow(msg, oids, handlers));
        } catch (error, stackTrace) {
          await _drainAndRethrow(error, stackTrace);
        }
        continue;
      }
      if (msg is CommandCompleteMessage) {
        continue;
      }
      if (msg is ReadyForQueryMessage) {
        return rows;
      }
      if (msg is ErrorResponseMessage) {
        await _throwAfterReadyForQuery(msg);
      }
      if (msg is RowDescriptionMessage) {
        continue;
      }
    }
  }

  Future<Object?> _executePreparedScalarFast(
    String statementName,
    DpgsqlParameterCollection? parameters,
    RowDescriptionMessage rowDescription,
  ) async {
    final params = parameters ?? DpgsqlParameterCollection();
    final parameterValues = <Uint8List?>[];
    final parameterFormatCodes = <int>[];

    _encodeParameters(params, parameterValues, parameterFormatCodes);

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

    Object? scalar;
    var hasScalar = false;
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
        if (!hasScalar && msg.columnCount > 0) {
          try {
            scalar = _decodeMaterializedValue(msg, 0, oids, handlers);
          } catch (error, stackTrace) {
            await _drainAndRethrow(error, stackTrace);
          }
          hasScalar = true;
        }
        continue;
      }
      if (msg is ReadyForQueryMessage) {
        return scalar;
      }
      if (msg is ErrorResponseMessage) {
        await _throwAfterReadyForQuery(msg);
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
    // A handler may decode to null (a JSON `null`): it came back as the raw
    // bytes.
    final handler = handlers[index];
    return handler != null ? handler.read(colData, isText: false) : colData;
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

  double _readNumericDouble(Uint8List payload, int offset, int length) =>
      NumericDoubleHandler.decodeBinary(payload, offset, length);

  /// An auto-prepared statement the server rejects after a schema change
  /// ("cached plan must not change result type", 0A000) or no longer has
  /// (26000) is unprepared, so that its next execution prepares it again. It
  /// used to fail on every later execution on this connection.
  void _invalidateAutoPrepared(PreparedStatement? statement, Object error) {
    if (statement == null ||
        error is! PostgresException ||
        (error.sqlState != '0A000' && error.sqlState != '26000')) {
      return;
    }
    final name = statement.name;
    if (name != null) {
      _preparedRowDescriptions.remove(name);
      _preparedMapMetadata.remove(name);
      _autoPreparedColumns.remove(name);
    }
    preparedStatementManager.invalidate(statement);
  }

  Future<void> _writePendingUnprepareMessages() async {
    final pending = preparedStatementManager.takePendingUnprepare();
    for (final statement in pending) {
      final name = statement.name;
      if (name == null || name.isEmpty) {
        continue;
      }
      _autoPreparedColumns.remove(name);
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
        await _throwAfterReadyForQuery(msg);
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

  /// Reads the answer to CopyFail: an error, then ReadyForQuery. It used to
  /// be left unread, so the next command read it as its own. A server that
  /// does not answer within [timeout] gets its connection closed instead.
  Future<void> awaitCopyFailAnswer(
      {Duration timeout = const Duration(seconds: 5)}) async {
    try {
      await awaitCopyComplete().timeout(timeout);
    } on PostgresException {
      // The expected answer.
    } on TimeoutException {
      await close();
    }
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
        await _throwAfterReadyForQuery(msg);
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
        await _throwAfterReadyForQuery(msg);
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

    // Send Parse, Bind, Execute without forcing a flush. Enqueued after: a
    // parameter that fails to encode leaves no command waiting for a response.
    await _sendQueryMessages(
      sql: sql,
      statementName: statementName,
      parameters: parameters,
      resultMode: resultMode,
    );
    _pipelineQueue!.enqueue(pendingCmd);

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
    final paramHandlers = <TypeHandler?>[];

    for (final p in params) {
      final handler = _resolveParameterHandler(p);
      paramOids.add(_parameterOid(handler));
      paramHandlers.add(handler);
    }

    // Encoded before anything is written (see executeReader).
    final encodedParams = <Uint8List?>[];
    final parameterFormatCodes = <int>[];
    for (var i = 0; i < params.length; i++) {
      _encodeParameter(
        params[i],
        paramHandlers[i],
        encodedParams,
        parameterFormatCodes,
      );
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

final class _PreparedMapMetadata {
  const _PreparedMapMetadata(this.columnNames, this.oids, this.handlers);

  final List<String> columnNames;
  final List<int> oids;
  final List<TypeHandler?> handlers;
}
