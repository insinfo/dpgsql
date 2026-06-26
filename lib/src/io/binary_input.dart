import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'uint8_list_pool.dart';

/// Leitura binária de alto nível com API síncrona (do ponto de vista do parser),
/// mas alimentada por IO assíncrono embaixo.
abstract class BinaryInput {
  /// Garante que pelo menos [count] bytes estarão disponíveis para leitura.
  Future<void> ensureBytes(int count);

  /// Lê um byte sem sinal.
  int readUint8();

  /// Lê um inteiro 16-bit big-endian.
  int readInt16();

  /// Lê um inteiro 16-bit sem sinal big-endian.
  int readUint16();

  /// Lê um inteiro 32-bit big-endian.
  int readInt32();

  /// Lê um inteiro 32-bit sem sinal big-endian.
  int readUint32();

  /// Lê um inteiro 64-bit big-endian.
  int readInt64();

  /// Lê [length] bytes brutos.
  List<int> readBytes(int length);
}

/// Implementação de [BinaryInput] que lê de um [Socket] com buffer interno
/// sem copiar todo o conteúdo a cada leitura.
class SocketBinaryInput implements BinaryInput {
  SocketBinaryInput(
    Stream<List<int>> stream, {
    int initialCapacity = 4096,
  }) : _buffer = Uint8ListPool.rent(initialCapacity) {
    _dataView = ByteData.view(_buffer.buffer);
    stream.listen(
      _onData,
      onDone: _onDone,
      onError: _onError,
      cancelOnError: true,
    );
  }

  Uint8List _buffer;
  late ByteData _dataView;
  int _readOffset = 0;
  int _writeLength = 0;

  bool _disposed = false;

  bool _done = false;
  Object? _error;
  StackTrace? _errorStackTrace;
  Completer<void>? _waitCompleter;

  int get _available => _writeLength - _readOffset;

  void _onData(List<int> data) {
    _appendData(data);
    _waitCompleter?..complete();
    _waitCompleter = null;
  }

  void _onDone() {
    _done = true;
    _waitCompleter?..complete();
    _waitCompleter = null;
  }

  void _onError(Object error, StackTrace stackTrace) {
    _done = true;
    _error = error;
    _errorStackTrace = stackTrace;
    _waitCompleter?.completeError(error, stackTrace);
    _waitCompleter = null;
  }

  Future<void> _checkForError() async {
    if (_error != null) {
      Error.throwWithStackTrace(
          _error!, _errorStackTrace ?? StackTrace.current);
    }
  }

  /// Adiciona novos dados ao buffer, realocando apenas quando necessário.
  void _appendData(List<int> data) {
    if (data.isEmpty) return;

    final free = _buffer.length - _writeLength;
    if (free >= data.length) {
      _buffer.setRange(_writeLength, _writeLength + data.length, data);
      _writeLength += data.length;
      return;
    }

    // Realoca crescendo a capacidade para evitar realocações frequentes.
    final unread = _writeLength - _readOffset;
    final needed = unread + data.length;
    if (needed <= _buffer.length) {
      // Move os dados não lidos para o início e escreve na sequência.
      if (unread > 0) {
        _buffer.setRange(0, unread, _buffer, _readOffset);
      }
      _readOffset = 0;
      _writeLength = unread;
      _buffer.setRange(_writeLength, _writeLength + data.length, data);
      _writeLength += data.length;
      return;
    }
    var newCapacity = _buffer.length * 2;
    if (newCapacity < needed) {
      newCapacity = needed;
    }
    final newBuffer = Uint8ListPool.rent(newCapacity);

    if (unread > 0) {
      newBuffer.setRange(0, unread, _buffer, _readOffset);
    }
    newBuffer.setRange(unread, unread + data.length, data);

    final oldBuffer = _buffer;
    _buffer = newBuffer;
    _dataView = ByteData.view(_buffer.buffer);
    _readOffset = 0;
    _writeLength = unread + data.length;
    Uint8ListPool.release(oldBuffer);
  }

  int _consumeOffset(int length) {
    if (length < 0) {
      throw ArgumentError.value(length, 'length', 'Deve ser >= 0');
    }
    if (_available < length) {
      throw StateError(
          'Buffer interno menor que o esperado: $_available < $length');
    }

    final startOffset = _readOffset;
    _readOffset += length;

    // Se consumiu tudo, reseta os ponteiros para liberar espaço.
    if (_readOffset == _writeLength) {
      _readOffset = 0;
      _writeLength = 0;
    }

    return startOffset;
  }

  @override
  Future<void> ensureBytes(int count) async {
    if (count < 0) {
      throw ArgumentError.value(count, 'count', 'Deve ser >= 0');
    }

    if (_disposed) {
      throw StateError('SocketBinaryInput já foi liberado');
    }

    await _checkForError();

    while (_available < count && !_done) {
      _waitCompleter ??= Completer<void>();
      await _waitCompleter!.future;
      await _checkForError();
    }

    await _checkForError();

    if (_available < count && _done) {
      throw StateError('EOF antes de ler $count bytes');
    }
  }

  @override
  int readUint8() {
    final offset = _consumeOffset(1);
    return _buffer[offset];
  }

  @override
  int readInt16() {
    final offset = _consumeOffset(2);
    return _dataView.getInt16(offset, Endian.big);
  }

  @override
  int readUint16() {
    final offset = _consumeOffset(2);
    return _dataView.getUint16(offset, Endian.big);
  }

  @override
  int readInt32() {
    final offset = _consumeOffset(4);
    return _dataView.getInt32(offset, Endian.big);
  }

  @override
  int readUint32() {
    final offset = _consumeOffset(4);
    return _dataView.getUint32(offset, Endian.big);
  }

  @override
  int readInt64() {
    final offset = _consumeOffset(8);
    return _dataView.getInt64(offset, Endian.big);
  }

  @override
  List<int> readBytes(int length) {
    if (_disposed) {
      throw StateError('SocketBinaryInput já foi liberado');
    }
    final offset = _consumeOffset(length);
    return Uint8List.sublistView(_buffer, offset, offset + length);
  }

  /// Libera o buffer atual de volta ao pool. Deve ser chamado quando o input
  /// não for mais utilizado.
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    Uint8ListPool.release(_buffer);
    _buffer = Uint8List(0);
    _dataView = ByteData(0);
    _readOffset = 0;
    _writeLength = 0;
  }
}

/// Implementação simples para buffers já carregados em memória.
class MemoryBinaryInput implements BinaryInput {
  MemoryBinaryInput(this._buffer);

  final Uint8List _buffer;
  int _offset = 0;

  Uint8List get buffer => _buffer;
  int get offset => _offset;
  int get _available => _buffer.length - _offset;
  int get remaining => _available;

  @override
  Future<void> ensureBytes(int count) async {
    if (count < 0) {
      throw ArgumentError.value(count, 'count', 'Deve ser >= 0');
    }
    if (_available < count) {
      throw StateError('EOF em MemoryBinaryInput: $_available < $count');
    }
  }

  @override
  int readUint8() {
    _ensureSync(1);
    return _buffer[_offset++];
  }

  @override
  int readInt16() {
    _ensureSync(2);
    final bd = ByteData.sublistView(_buffer, _offset, _offset + 2);
    _offset += 2;
    return bd.getInt16(0, Endian.big);
  }

  @override
  int readUint16() {
    _ensureSync(2);
    final bd = ByteData.sublistView(_buffer, _offset, _offset + 2);
    _offset += 2;
    return bd.getUint16(0, Endian.big);
  }

  @override
  int readInt32() {
    _ensureSync(4);
    final bd = ByteData.sublistView(_buffer, _offset, _offset + 4);
    _offset += 4;
    return bd.getInt32(0, Endian.big);
  }

  @override
  int readUint32() {
    _ensureSync(4);
    final bd = ByteData.sublistView(_buffer, _offset, _offset + 4);
    _offset += 4;
    return bd.getUint32(0, Endian.big);
  }

  @override
  int readInt64() {
    _ensureSync(8);
    final bd = ByteData.sublistView(_buffer, _offset, _offset + 8);
    _offset += 8;
    return bd.getInt64(0, Endian.big);
  }

  @override
  List<int> readBytes(int length) {
    _ensureSync(length);
    final slice = Uint8List.sublistView(_buffer, _offset, _offset + length);
    _offset += length;
    return slice;
  }

  void skipBytes(int length) {
    _ensureSync(length);
    _offset += length;
  }

  void _ensureSync(int length) {
    if (length < 0) {
      throw ArgumentError.value(length, 'length', 'Deve ser >= 0');
    }
    if (_available < length) {
      throw StateError('EOF em MemoryBinaryInput: $_available < $length');
    }
  }
}
