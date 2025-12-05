import 'dart:typed_data';

import '../io/binary_input.dart';
import '../io/binary_output.dart';

/// Representa uma mensagem do protocolo PostgreSQL (1 byte de tipo + length + payload).
class PostgresMessage {
  PostgresMessage(this.typeCode, this.length, this.payload)
      : assert(length >= 4, 'length inclui os 4 bytes do próprio length'),
        assert(payload.length == length - 4,
            'payload precisa ter length-4 bytes');

  /// Código do tipo da mensagem (um byte ASCII, ex: 'R', 'K', 'Z').
  final int typeCode;

  /// Tamanho total informado no header (inclui os 4 bytes do length).
  final int length;

  /// Dados do corpo (length - 4 bytes).
  final Uint8List payload;
}

/// Lê mensagens do servidor em cima de um [BinaryInput].
class PostgresMessageReader {
  PostgresMessageReader(this._input);

  final BinaryInput _input;

  /// Lê a próxima mensagem (1 byte de tipo + int32 de tamanho + corpo).
  Future<PostgresMessage> readMessage() async {
    await _input.ensureBytes(5);
    final typeCode = _input.readUint8();
    final length = _input.readInt32();
    if (length < 4) {
      throw StateError('Tamanho de mensagem inválido: $length');
    }

    final bodyLength = length - 4;
    await _input.ensureBytes(bodyLength);
    final payload = Uint8List.fromList(_input.readBytes(bodyLength));

    return PostgresMessage(typeCode, length, payload);
  }
}

/// Monta mensagens para envio ao servidor usando um [BinaryOutput].
class PostgresMessageWriter {
  PostgresMessageWriter(this._output);

  final BinaryOutput _output;

  /// Exponibiliza o [BinaryOutput] subjacente para mensagens que não usam type code
  /// (ex.: SSLRequest/StartupMessage).
  BinaryOutput get output => _output;

  /// Escreve uma mensagem: [typeCode] + length + corpo gerado por [buildBody].
  ///
  /// A função [buildBody] recebe um [BinaryOutput] em memória para montar o
  /// payload. Depois o payload é escrito no destino com o length correto.
  Future<void> writeMessage(
    int typeCode,
    void Function(BinaryOutput body) buildBody,
  ) async {
    final bodyBuffer = MemoryBinaryOutput(initialCapacity: 256);
    buildBody(bodyBuffer);

    final payload = bodyBuffer.toUint8List();
    final length = payload.length + 4;

    _output.writeUint8(typeCode);
    _output.writeInt32(length);
    _output.writeBytes(payload);
    await _output.flush();
  }
}
