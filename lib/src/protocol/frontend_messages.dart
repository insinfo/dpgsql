import 'dart:typed_data';

import '../io/binary_output.dart';
import 'postgres_message.dart';

/// Constantes de protocolo usadas durante o handshake.
class PostgresProtocol {
  const PostgresProtocol._();

  /// Versão 3.0 (major 3, minor 0) em 32 bits.
  static const int protocolVersion = (3 << 16) | 0;

  /// Solicitação de upgrade para SSL (valor mágico do protocolo).
  static const int sslRequestCode = 80877103; // 0x04D2162F
}

/// Helpers para escrever mensagens de frontend usando [PostgresMessageWriter].
class FrontendMessages {
  FrontendMessages(this._writer);

  final PostgresMessageWriter _writer;

  /// Envia um SSLRequest (sem type code; apenas length + magic).
  Future<void> writeSslRequest() async {
    // SSLRequest: int32 length (8) + int32 code (0x04D2162F)
    // Não possui type code, é mensagem "sem tipo" na conexão inicial.
    _writer.output
      ..writeInt32(8)
      ..writeInt32(PostgresProtocol.sslRequestCode);
    await _writer.output.flush();
  }

  /// Envia uma StartupMessage (sem type code; apenas length + protocol version + parâmetros).
  Future<void> writeStartupMessage({
    required String user,
    String? database,
    Map<String, String> parameters = const {},
  }) async {
    final body = MemoryBinaryOutput(initialCapacity: 256);
    body.writeInt32(PostgresProtocol.protocolVersion);
    body.writeBytes(_encodeCString('user'));
    body.writeBytes(_encodeCString(user));

    if (database != null) {
      body.writeBytes(_encodeCString('database'));
      body.writeBytes(_encodeCString(database));
    }

    parameters.forEach((k, v) {
      body.writeBytes(_encodeCString(k));
      body.writeBytes(_encodeCString(v));
    });

    // Terminador final vazio.
    body.writeUint8(0);

    final payload = body.toUint8List();
    final length = payload.length + 4; // inclui os 4 bytes do próprio length

    _writer.output.writeInt32(length);
    _writer.output.writeBytes(payload);
    await _writer.output.flush();
  }

  /// Envia uma mensagem Query ('Q' + length + sql + terminador).
  Future<void> writeQuery(String sql) async {
    await _writer.writeMessage(_charCode('Q'), (body) {
      body.writeBytes(_encodeCString(sql));
    });
  }

  /// Parse: 'P' + statement name + query + parameter type oids (int16 count + int32 oids).
  Future<void> writeParse({
    String statementName = '',
    required String query,
    List<int> parameterTypeOids = const [],
  }) async {
    await _writer.writeMessage(_charCode('P'), (body) {
      body.writeBytes(_encodeCString(statementName));
      body.writeBytes(_encodeCString(query));
      body.writeInt16(parameterTypeOids.length);
      for (final oid in parameterTypeOids) {
        body.writeInt32(oid);
      }
    });
  }

  /// Bind: 'B' + portal + statement + format codes + values + result formats.
  Future<void> writeBind({
    String portalName = '',
    String statementName = '',
    List<int> parameterFormatCodes = const [],
    List<List<int>?> parameterValues = const [],
    List<int> resultFormatCodes = const [],
  }) async {
    if (parameterFormatCodes.isNotEmpty &&
        parameterFormatCodes.length != 1 &&
        parameterFormatCodes.length != parameterValues.length) {
      throw ArgumentError(
          'parameterFormatCodes deve ter 0, 1 ou o mesmo tamanho de parameterValues');
    }
    if (resultFormatCodes.isNotEmpty &&
        resultFormatCodes.length != 1 &&
        resultFormatCodes.length != parameterValues.length) {
      // No protocolo é relacionado ao número de colunas retornadas; aqui exigimos consistência simples.
      throw ArgumentError(
          'resultFormatCodes deve ter 0, 1 ou o mesmo tamanho de parameterValues');
    }

    await _writer.writeMessage(_charCode('B'), (body) {
      body.writeBytes(_encodeCString(portalName));
      body.writeBytes(_encodeCString(statementName));

      // Parameter formats
      body.writeInt16(parameterFormatCodes.length);
      for (final fmt in parameterFormatCodes) {
        body.writeInt16(fmt);
      }

      // Parameter values
      body.writeInt16(parameterValues.length);
      for (final value in parameterValues) {
        if (value == null) {
          body.writeInt32(-1); // NULL
        } else {
          body.writeInt32(value.length);
          body.writeBytes(value);
        }
      }

      // Result formats
      body.writeInt16(resultFormatCodes.length);
      for (final fmt in resultFormatCodes) {
        body.writeInt16(fmt);
      }
    });
  }

  /// Describe: 'D' + (byte: 'S' para statement, 'P' para portal) + nome.
  Future<void> writeDescribeStatement(String statementName) async {
    await _writeDescribe(_charCode('S'), statementName);
  }

  Future<void> writeDescribePortal(String portalName) async {
    await _writeDescribe(_charCode('P'), portalName);
  }

  Future<void> _writeDescribe(int target, String name) async {
    await _writer.writeMessage(_charCode('D'), (body) {
      body.writeUint8(target);
      body.writeBytes(_encodeCString(name));
    });
  }

  /// Execute: 'E' + portal + max rows.
  Future<void> writeExecute({String portalName = '', int maxRows = 0}) async {
    await _writer.writeMessage(_charCode('E'), (body) {
      body.writeBytes(_encodeCString(portalName));
      body.writeInt32(maxRows);
    });
  }

  /// Sync: 'S' sem payload.
  Future<void> writeSync() => _writer.writeMessage(_charCode('S'), (_) {});

  /// Terminate: 'X' sem payload.
  Future<void> writeTerminate() => _writer.writeMessage(_charCode('X'), (_) {});

  /// CancelRequest: Length(16) + Code(80877102) + PID + Key.
  /// Note: This is sent on a new connection, not wrapped in a standard message.
  Future<void> writeCancelRequest(int processId, int secretKey) async {
    final buffer = _writer.output;
    buffer.writeInt32(16); // Length
    buffer.writeInt32(80877102); // CancelRequest Code
    buffer.writeInt32(processId);
    buffer.writeInt32(secretKey);
    await buffer.flush();
  }

  Future<void> writePassword(String password) async {
    await _writer.writeMessage(_charCode('p'), (body) {
      body.writeBytes(_encodeCString(password));
    });
  }

  /// SASLInitialResponse: 'p' + mech(CString) + len(Int32) + data(Bytes).
  Future<void> writeSASLInitialResponse(
      String mechanism, String initialData) async {
    await _writer.writeMessage(_charCode('p'), (body) {
      body.writeBytes(_encodeCString(mechanism));
      if (initialData.isEmpty) {
        body.writeInt32(-1);
      } else {
        final bytes = _encodeString(initialData); // Not CString, just bytes
        body.writeInt32(bytes.length);
        body.writeBytes(bytes);
      }
    });
  }

  /// SASLResponse: 'p' + data(Bytes).
  Future<void> writeSASLResponse(String data) async {
    await _writer.writeMessage(_charCode('p'), (body) {
      final bytes = _encodeString(data);
      body.writeBytes(bytes);
    });
  }

  Uint8List _encodeString(String value) {
    return Uint8List.fromList(value.codeUnits); // UTF8?
  }

  Uint8List _encodeCString(String value) {
    final codeUnits = value.codeUnits;
    final out = Uint8List(codeUnits.length + 1);
    out.setRange(0, codeUnits.length, codeUnits);
    out[codeUnits.length] = 0;
    return out;
  }

  /// CopyData: 'd' + data.
  Future<void> writeCopyData(Uint8List data) async {
    await _writer.writeMessage(_charCode('d'), (body) {
      body.writeBytes(data);
    });
  }

  /// CopyDone: 'c'.
  Future<void> writeCopyDone() async {
    await _writer.writeMessage(_charCode('c'), (_) {});
  }

  /// CopyFail: 'f' + error message.
  Future<void> writeCopyFail(String message) async {
    await _writer.writeMessage(_charCode('f'), (body) {
      body.writeBytes(_encodeCString(message));
    });
  }

  int _charCode(String char) {
    if (char.length != 1) {
      throw ArgumentError.value(char, 'char', 'Precisa ter 1 caractere');
    }
    return char.codeUnitAt(0);
  }
}
