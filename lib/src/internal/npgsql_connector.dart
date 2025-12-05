import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/export.dart' as pc;
import 'dart:convert';

import '../io/binary_input.dart';
import '../io/binary_output.dart';
import '../protocol/backend_messages.dart';
import '../protocol/frontend_messages.dart';
import '../protocol/postgres_message.dart';
import '../postgres_exception.dart';
import '../npgsql_data_reader.dart';
import '../npgsql_parameter_collection.dart';
import '../types/type_handler.dart';
import 'npgsql_data_reader_impl.dart';
import 'scram_authenticator.dart';

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
  // SocketBinaryInput? _connectionStream; // Npgsql: Stream
  SocketBinaryInput? _readBuffer; // Npgsql: NpgsqlReadBuffer
  SocketBinaryOutput? _writeBuffer; // Npgsql: NpgsqlWriteBuffer

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

  Future<void> _handleStartup() async {
    // Write Startup Message
    // TODO: SSL negotiation would happen before this
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

      // Ignore other messages/Notices for now
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

  Future<IBackendMessage> readMessage() async {
    return _readMessage();
  }

  Future<IBackendMessage> _readMessage() async {
    final raw = await _msgReader!.readMessage();
    return _backendReader.parse(raw);
  }

  Future<NpgsqlDataReader> executeReader(String sql,
      {NpgsqlParameterCollection? parameters}) async {
    if (parameters != null && parameters.isNotEmpty) {
      // Extended Query Protocol
      // 1. Parse (Prepare)
      await _frontendMessages!.writeParse(
        query: sql,
        // TODO: Type OIDs inference for parameterTypes?
      );

      // 2. Bind
      final values = <Uint8List?>[];
      final formatCodes = <int>[];

      for (final p in parameters) {
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
      // Simple Query Protocol
      await _frontendMessages!.writeQuery(sql);
      final reader = NpgsqlDataReaderImpl(this);
      await reader.init();
      return reader;
    }
  }

  Future<void> executeCopyCommand(String sql) async {
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
        if (msg.kind == CopyResponseKind.copyIn) {
          return;
        }
        // If copyOut/Both not supported yet
        throw PostgresException(
            severity: 'ERROR',
            invariantSeverity: 'ERROR',
            sqlState: '0A000',
            messageText: 'Unexpected CopyResponseKind: ${msg.kind}');
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

  Future<void> close() async {
    try {
      await _frontendMessages?.writeTerminate();
    } catch (_) {
      // Ignore errors sending terminate
    }
    await _socket?.close();
    _isConnected = false;
  }

  String _computeMD5(String username, String password, Uint8List salt) {
    // 1. md5(password + user)
    // Npgsql: MD5.Create().ComputeHash(Encoding.UTF8.GetBytes(password + username));
    final pwdUser = utf8.encode(password + username);
    final d1 = pc.MD5Digest().process(Uint8List.fromList(pwdUser));
    final hash1 = _toHex(d1);

    // 2. md5(hash1 + salt)
    // Npgsql: MD5.Create().ComputeHash(Encoding.ASCII.GetBytes(hash1).Concat(salt).ToArray());
    final hash1Bytes = utf8.encode(hash1);
    final msg = Uint8List.fromList([...hash1Bytes, ...salt]);
    final d2 = pc.MD5Digest().process(msg);
    final hash2 = _toHex(d2);

    return 'md5' + hash2;
  }

  String _toHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Sends a CancelRequest to the backend to cancel the current query.
  /// This establishes a temporary new connection.
  Future<void> cancelRequest() async {
    if (_backendProcessId == 0 || _backendSecretKey == 0) {
      // Not connected or handshake not done?
      return;
    }

    try {
      final s = await Socket.connect(host, port);
      s.setOption(SocketOption.tcpNoDelay, true);
      final out = SocketBinaryOutput(s);
      final writer = PostgresMessageWriter(out);
      final fe = FrontendMessages(writer);

      await fe.writeCancelRequest(_backendProcessId, _backendSecretKey);
      await s.flush();
      await s.close();
    } catch (e) {
      // Ignore errors during cancellation request
    }
  }
}
