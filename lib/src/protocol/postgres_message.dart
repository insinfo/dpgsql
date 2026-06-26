import 'dart:typed_data';

import '../io/binary_input.dart';
import '../io/binary_output.dart';
import '../io/write_buffer.dart';

/// Representa uma mensagem do protocolo PostgreSQL (1 byte de tipo + length + payload).
class PostgresMessage {
  PostgresMessage(this.typeCode, this.length, this.payload)
      : assert(length >= 4, 'length inclui os 4 bytes do próprio length'),
        assert(
            payload.length == length - 4, 'payload precisa ter length-4 bytes');

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
    if (_input.availableBytes < 5) {
      await _input.ensureBytes(5);
    }
    final typeCode = _input.readUint8();
    final length = _input.readInt32();
    if (length < 4) {
      throw StateError('Tamanho de mensagem inválido: $length');
    }

    final bodyLength = length - 4;
    if (_input.availableBytes < bodyLength) {
      await _input.ensureBytes(bodyLength);
    }
    final rawPayload = _input.readBytes(bodyLength);
    final payload =
        (rawPayload is Uint8List) ? rawPayload : Uint8List.fromList(rawPayload);

    return PostgresMessage(typeCode, length, payload);
  }
}

/// Monta mensagens para envio ao servidor usando um [BinaryOutput].
class PostgresMessageWriter {
  PostgresMessageWriter(
    BinaryOutput output, {
    bool useBuffer = false,
    int bufferSize = 8192,
    int initialBodyCapacity = 512,
  })  : _output = output,
        _buffer = useBuffer
            ? WriteBuffer(maxBufferSize: bufferSize, output: output)
            : null,
        _scratchBuffer = MemoryBinaryOutput(
          initialCapacity: initialBodyCapacity,
        );

  final BinaryOutput _output;
  final WriteBuffer? _buffer;
  final MemoryBinaryOutput _scratchBuffer;
  bool _scratchInUse = false;

  /// Buffer opcional para escritas agregadas.
  WriteBuffer? get buffer => _buffer;

  /// Exponibiliza o [BinaryOutput] subjacente para mensagens que não usam type code
  /// (ex.: SSLRequest/StartupMessage).
  ///
  /// IMPORTANTE: Se o buffering estiver ativo, chama flush() antes de retornar
  /// para garantir ordem correta das mensagens.
  Future<BinaryOutput> getOutput() async {
    final buffer = _buffer;
    if (buffer != null && buffer.hasPending) {
      await buffer.flush();
    }
    return _output;
  }

  /// Acesso síncrono ao output (cuidado: pode quebrar ordem se houver buffer pendente).
  /// Preferir [getOutput()].
  BinaryOutput get output => _output;

  /// Escreve uma mensagem: [typeCode] + length + corpo gerado por [buildBody].
  ///
  /// A função [buildBody] recebe um [BinaryOutput] em memória para montar o
  /// payload. Depois o payload é escrito no destino com o length correto.
  ///
  /// Se [useBuffer] for true no construtor, a mensagem é enfileirada no buffer
  /// e [flush] deve ser chamado manualmente (ou via [flushIfNeeded]).
  Future<void> writeMessage(
    int typeCode,
    void Function(BinaryOutput body) buildBody, {
    bool flush = true,
  }) async {
    if (_scratchInUse) {
      throw StateError(
          'PostgresMessageWriter.writeMessage chamado de forma concorrente');
    }
    _scratchInUse = true;

    final bodyBuffer = _scratchBuffer;
    bodyBuffer.reset();

    try {
      buildBody(bodyBuffer);

      final payload = bodyBuffer.toUint8List();
      final length = payload.length + 4;

      final buffer = _buffer;
      if (buffer != null) {
        // Buffered write
        final message = MemoryBinaryOutput(initialCapacity: length + 1);
        message.writeUint8(typeCode);
        message.writeInt32(length);
        message.writeBytes(payload);
        buffer.enqueue(message.toUint8List());

        if (flush) {
          await buffer.flush();
        } else {
          await buffer.flushIfNeeded();
        }
      } else {
        // Direct write
        _output.writeUint8(typeCode);
        _output.writeInt32(length);
        _output.writeBytes(payload);

        if (flush) {
          await _output.flush();
        }
      }
    } finally {
      bodyBuffer.reset();
      _scratchInUse = false;
    }
  }

  /// Flush explícito do buffer (se existir) ou do output.
  Future<void> flush() async {
    final buffer = _buffer;
    if (buffer != null) {
      await buffer.flush();
    } else {
      await _output.flush();
    }
  }

  /// Flush condicional quando o buffer atingir o limite configurado.
  Future<void> flushIfNeeded() async {
    final buffer = _buffer;
    if (buffer != null) {
      await buffer.flushIfNeeded();
    }
  }
}
