import 'dart:async';
import 'dart:typed_data';

import 'npgsql_large_object_manager.dart';

/// An interface to remotely control the seekable stream for an opened large object on a PostgreSQL server.
/// Note that the OpenRead/OpenReadWrite method as well as all operations performed on this stream must be wrapped inside a database transaction.
/// Porting NpgsqlLargeObjectStream.cs
class NpgsqlLargeObjectStream {
  NpgsqlLargeObjectStream(this._manager, this._fd, this._writeable);

  final NpgsqlLargeObjectManager _manager;
  final int _fd;
  final bool _writeable;
  bool _isDisposed = false;

  /// Whether the stream has write permission.
  bool get canWrite => _writeable && !_isDisposed;

  /// Whether the stream has read permission.
  bool get canRead => !_isDisposed;

  /// Whether the stream can seek.
  bool get canSeek => !_isDisposed;

  void _checkDisposed() {
    if (_isDisposed) {
      throw StateError('Cannot access a disposed large object stream');
    }
  }

  /// Reads [count] bytes from the large object.
  /// The only case when fewer bytes are read is when end of stream is reached.
  Future<Uint8List> read(int count) async {
    _checkDisposed();
    final bytes = await _manager.loRead(_fd, count);
    return bytes;
  }

  /// Writes data to the large object.
  Future<int> write(Uint8List data) async {
    _checkDisposed();
    if (!_writeable) {
      throw StateError('Stream is not writeable');
    }
    final written = await _manager.loWrite(_fd, data);
    return written;
  }

  /// Gets the current position in the stream.
  Future<int> getPosition() async {
    _checkDisposed();
    return _manager.loTell64(_fd);
  }

  /// Gets the length of the large object.
  /// This internally seeks to the end of the stream to retrieve the length, and then back again.
  Future<int> getLength() async {
    _checkDisposed();
    final oldPosition = await _manager.loTell64(_fd);
    final length = await _manager.loSeek64(_fd, 0, 2); // SEEK_END
    await _manager.loSeek64(_fd, oldPosition, 0); // SEEK_SET
    return length;
  }

  /// Seeks in the stream to the specified position.
  /// [origin]: 0 = SEEK_SET (from beginning), 1 = SEEK_CUR (from current), 2 = SEEK_END (from end)
  Future<int> seek(int offset, [int origin = 0]) async {
    _checkDisposed();
    final newPos = await _manager.loSeek64(_fd, offset, origin);
    return newPos;
  }

  /// Truncates or enlarges the large object to the given size.
  /// If enlarging, the large object is extended with null bytes.
  Future<void> setLength(int length) async {
    _checkDisposed();
    if (!_writeable) {
      throw StateError('Stream is not writeable');
    }
    await _manager.loTruncate64(_fd, length);
  }

  /// Releases resources at the backend allocated for this stream.
  Future<void> close() async {
    if (_isDisposed) return;
    _isDisposed = true;
    await _manager.loClose(_fd);
  }

  /// Disposes of the stream (alias for close).
  Future<void> dispose() => close();
}
