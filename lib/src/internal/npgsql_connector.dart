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

/// Represents a connection to a PostgreSQL backend.
/// Porting NpgsqlConnector.cs
class NpgsqlConnector {
  NpgsqlConnector({
    required this.host,
    this.port = 5432,
    this.username = 'postgres',
    this.password = '',
    this.database = 'postgres',
    this.sslMode = 'Disable', // TODO: Enum SslMode
  });

  final String host;
  final int port;
  final String username;
  final String password;
  final String database;
  final String sslMode;

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

      // 2. Initialize Buffers
      _readBuffer = SocketBinaryInput(_socket!);
      _writeBuffer = SocketBinaryOutput(_socket!);

      // Readers/Writers helpers
      _msgReader = PostgresMessageReader(_readBuffer!);
      _msgWriter = PostgresMessageWriter(_writeBuffer!);
      _frontendMessages = FrontendMessages(_msgWriter!);
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
    await _frontendMessages!.writeStartupMessage(
      user: username,
      database: database,
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
      // Optional: verify server signature
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

  Future<IBackendMessage> readMessage() async {
    return _readMessage();
  }

  Future<IBackendMessage> _readMessage() async {
    final raw = await _msgReader!.readMessage();
    return _backendReader.parse(raw);
  }

  Future<void> prepare(String sql, String statementName,
      NpgsqlParameterCollection parameters) async {
    // 1. Parse (Prepare)
    final paramOids = <int>[];
    for (final p in parameters) {
      if (p.value != null) {
        final handler = _typeRegistry.resolveByValue(p.value);
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
            values.add(utf8.encode(p.value.toString()));
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

    // Pipeline all commands
    for (final cmd in batch.batchCommands) {
      // Rewrite SQL if needed
      String sqlToExecute = cmd.commandText;
      NpgsqlParameterCollection paramsToUse = cmd.parameters;

      if (cmd.parameters.isNotEmpty) {
        final rewritten = SqlRewriter.rewrite(cmd.commandText, cmd.parameters);
        sqlToExecute = rewritten.sql;
        paramsToUse = NpgsqlParameterCollection();
        paramsToUse.addAll(rewritten.orderedParameters);
      }

      // Parse (Unnamed)
      final paramOids = <int>[];
      for (final p in paramsToUse) {
        final handler = _typeRegistry.resolveByValue(p.value);
        paramOids.add(handler?.oid ?? 0);
      }

      await _frontendMessages!
          .writeParse(query: sqlToExecute, parameterTypeOids: paramOids);

      // Bind (Unnamed Portal -> Unnamed Statement)
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
            values.add(utf8.encode(p.value.toString()));
            formatCodes.add(0); // Text
          }
        }
      }

      await _frontendMessages!.writeBind(
        portalName: '',
        statementName: '',
        parameterValues: values,
        parameterFormatCodes: formatCodes,
        resultFormatCodes: [1], // Request Binary results
      );

      // Describe Portal (Unnamed)
      await _frontendMessages!.writeDescribePortal('');

      // Execute (Unnamed Portal)
      await _frontendMessages!.writeExecute();
    }

    // Sync at the end
    await _frontendMessages!.writeSync();

    // Return reader
    final reader = NpgsqlDataReaderImpl(this);
    await reader.init();
    return reader;
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
}
