import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Leitura binária de alto nível com API síncrona (do ponto de vista do parser),
/// mas alimentada por IO assíncrono embaixo.
abstract class BinaryInput {
  /// Garante que pelo menos [count] bytes estarão disponíveis para leitura.
  Future<void> ensureBytes(int count);

  /// Lê um byte sem sinal.
  int readUint8();

  /// Lê um inteiro 16-bit big-endian.
  int readInt16();

  /// Lê um inteiro 32-bit big-endian.
  int readInt32();

  /// Lê [length] bytes brutos.
  List<int> readBytes(int length);
}

/// Implementação de [BinaryInput] que lê de um [Socket] com buffer interno
/// sem copiar todo o conteúdo a cada leitura.
class SocketBinaryInput implements BinaryInput {
  SocketBinaryInput(
    Stream<List<int>> stream, {
    int initialCapacity = 4096,
  }) : _buffer = Uint8List(initialCapacity) {
    stream.listen(
      _onData,
      onDone: _onDone,
      onError: _onError,
      cancelOnError: true,
    );
  }

  Uint8List _buffer;
  int _readOffset = 0;
  int _writeLength = 0;

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
    var newCapacity = _buffer.length * 2;
    if (newCapacity < needed) {
      newCapacity = needed;
    }
    final newBuffer = Uint8List(newCapacity);

    if (unread > 0) {
      newBuffer.setRange(0, unread, _buffer.sublist(_readOffset, _writeLength));
    }
    newBuffer.setRange(unread, unread + data.length, data);

    _buffer = newBuffer;
    _readOffset = 0;
    _writeLength = unread + data.length;
  }

  Uint8List _consume(int length) {
    if (length < 0) {
      throw ArgumentError.value(length, 'length', 'Deve ser >= 0');
    }
    if (_available < length) {
      throw StateError(
          'Buffer interno menor que o esperado: $_available < $length');
    }

    final view =
        Uint8List.sublistView(_buffer, _readOffset, _readOffset + length);
    _readOffset += length;

    // Se consumiu tudo, reseta os ponteiros para liberar espaço.
    if (_readOffset == _writeLength) {
      _readOffset = 0;
      _writeLength = 0;
    }

    return view;
  }

  @override
  Future<void> ensureBytes(int count) async {
    if (count < 0) {
      throw ArgumentError.value(count, 'count', 'Deve ser >= 0');
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
    final chunk = _consume(1);
    return chunk[0];
  }

  @override
  int readInt16() {
    final chunk = _consume(2);
    final bd = ByteData.sublistView(chunk);
    return bd.getInt16(0, Endian.big);
  }

  @override
  int readInt32() {
    final chunk = _consume(4);
    final bd = ByteData.sublistView(chunk);
    return bd.getInt32(0, Endian.big);
  }

  @override
  List<int> readBytes(int length) {
    return _consume(length);
  }
}

/// Implementação simples para buffers já carregados em memória.
class MemoryBinaryInput implements BinaryInput {
  MemoryBinaryInput(this._buffer);

  final Uint8List _buffer;
  int _offset = 0;

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
  int readInt32() {
    _ensureSync(4);
    final bd = ByteData.sublistView(_buffer, _offset, _offset + 4);
    _offset += 4;
    return bd.getInt32(0, Endian.big);
  }

  @override
  List<int> readBytes(int length) {
    _ensureSync(length);
    final slice = Uint8List.sublistView(_buffer, _offset, _offset + length);
    _offset += length;
    return slice;
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
