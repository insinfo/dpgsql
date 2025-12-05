import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Escrita binária com API síncrona para compor mensagens e flush assíncrono.
abstract class BinaryOutput {
  /// Quantos bytes estão acumulados no buffer.
  int get length;

  /// Garante que o buffer comporte [count] bytes adicionais.
  void ensureCapacity(int count);

  /// Escreve um byte sem sinal.
  void writeUint8(int value);

  /// Escreve um inteiro 16-bit big-endian.
  void writeInt16(int value);

  /// Escreve um inteiro 32-bit big-endian.
  void writeInt32(int value);

  /// Escreve bytes brutos.
  void writeBytes(List<int> bytes);

  /// Força envio do buffer para o destino (socket/IOSink).
  Future<void> flush();
}

/// Implementação de [BinaryOutput] com buffer reutilizável sobre um [IOSink]
/// (por exemplo, `Socket`).
class SocketBinaryOutput implements BinaryOutput {
  SocketBinaryOutput(
    this._sink, {
    int initialCapacity = 4096,
  }) : _buffer = Uint8List(initialCapacity);

  final IOSink _sink;

  Uint8List _buffer;
  int _writeOffset = 0;

  @override
  int get length => _writeOffset;

  @override
  void ensureCapacity(int count) {
    if (count < 0) {
      throw ArgumentError.value(count, 'count', 'Deve ser >= 0');
    }
    final needed = _writeOffset + count;
    if (needed <= _buffer.length) return;

    var newCapacity = _buffer.length * 2;
    if (newCapacity < needed) {
      newCapacity = needed;
    }
    final newBuf = Uint8List(newCapacity);
    newBuf.setRange(0, _writeOffset, _buffer);
    _buffer = newBuf;
  }

  @override
  void writeUint8(int value) {
    if (value < 0 || value > 0xFF) {
      throw RangeError.range(value, 0, 0xFF, 'value');
    }
    ensureCapacity(1);
    _buffer[_writeOffset++] = value;
  }

  @override
  void writeInt16(int value) {
    if (value < -0x8000 || value > 0x7FFF) {
      throw RangeError.range(value, -0x8000, 0x7FFF, 'value');
    }
    ensureCapacity(2);
    final bd = ByteData.sublistView(_buffer, _writeOffset, _writeOffset + 2);
    bd.setInt16(0, value, Endian.big);
    _writeOffset += 2;
  }

  @override
  void writeInt32(int value) {
    if (value < -0x80000000 || value > 0x7FFFFFFF) {
      throw RangeError.range(value, -0x80000000, 0x7FFFFFFF, 'value');
    }
    ensureCapacity(4);
    final bd = ByteData.sublistView(_buffer, _writeOffset, _writeOffset + 4);
    bd.setInt32(0, value, Endian.big);
    _writeOffset += 4;
  }

  @override
  void writeBytes(List<int> bytes) {
    ensureCapacity(bytes.length);
    _buffer.setRange(_writeOffset, _writeOffset + bytes.length, bytes);
    _writeOffset += bytes.length;
  }

  @override
  Future<void> flush() async {
    if (_writeOffset > 0) {
      _sink.add(Uint8List.sublistView(_buffer, 0, _writeOffset));
      _writeOffset = 0;
    }
    await _sink.flush();
  }
}

/// Variante em memória para testes ou construção de payloads.
class MemoryBinaryOutput implements BinaryOutput {
  MemoryBinaryOutput({int initialCapacity = 256})
      : _buffer = Uint8List(initialCapacity);

  Uint8List _buffer;
  int _writeOffset = 0;

  @override
  int get length => _writeOffset;

  @override
  void ensureCapacity(int count) {
    if (count < 0) {
      throw ArgumentError.value(count, 'count', 'Deve ser >= 0');
    }
    final needed = _writeOffset + count;
    if (needed <= _buffer.length) return;

    var newCapacity = _buffer.length * 2;
    if (newCapacity < needed) {
      newCapacity = needed;
    }
    final newBuf = Uint8List(newCapacity);
    newBuf.setRange(0, _writeOffset, _buffer);
    _buffer = newBuf;
  }

  @override
  void writeUint8(int value) {
    if (value < 0 || value > 0xFF) {
      throw RangeError.range(value, 0, 0xFF, 'value');
    }
    ensureCapacity(1);
    _buffer[_writeOffset++] = value;
  }

  @override
  void writeInt16(int value) {
    if (value < -0x8000 || value > 0x7FFF) {
      throw RangeError.range(value, -0x8000, 0x7FFF, 'value');
    }
    ensureCapacity(2);
    final bd = ByteData.sublistView(_buffer, _writeOffset, _writeOffset + 2);
    bd.setInt16(0, value, Endian.big);
    _writeOffset += 2;
  }

  @override
  void writeInt32(int value) {
    if (value < -0x80000000 || value > 0x7FFFFFFF) {
      throw RangeError.range(value, -0x80000000, 0x7FFFFFFF, 'value');
    }
    ensureCapacity(4);
    final bd = ByteData.sublistView(_buffer, _writeOffset, _writeOffset + 4);
    bd.setInt32(0, value, Endian.big);
    _writeOffset += 4;
  }

  @override
  void writeBytes(List<int> bytes) {
    ensureCapacity(bytes.length);
    _buffer.setRange(_writeOffset, _writeOffset + bytes.length, bytes);
    _writeOffset += bytes.length;
  }

  /// Obtém uma view dos bytes escritos até agora.
  Uint8List toUint8List() => Uint8List.sublistView(_buffer, 0, _writeOffset);

  @override
  Future<void> flush() async {
    // Nada a fazer: em memória não flusha.
  }
}
