import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'internal/dpgsql_connector.dart';
import 'protocol/backend_messages.dart';

typedef DpgsqlCopyProgressCallback = void Function(int bytesTransferred);

/// Raw COPY stream for COPY TO STDOUT and COPY FROM STDIN.
///
/// This is the low-level COPY API closest to NpgsqlRawCopyStream. It does not
/// parse rows or encode values; callers provide and receive raw COPY payload
/// chunks. It works for binary, text, and CSV COPY formats.
class DpgsqlRawCopyStream {
  DpgsqlRawCopyStream(
    this._connector,
    this._copyCommand,
    this._onClosed,
    this._onProgress,
  );

  final DpgsqlConnector _connector;
  final String _copyCommand;
  final void Function(bool reusable) _onClosed;
  final DpgsqlCopyProgressCallback? _onProgress;

  CopyResponseKind? _kind;
  bool _closed = false;
  bool _completed = false;
  int _bytesTransferred = 0;

  int get bytesTransferred => _bytesTransferred;

  bool get isClosed => _closed;

  bool get canRead =>
      !_closed &&
      (_kind == CopyResponseKind.copyOut || _kind == CopyResponseKind.copyBoth);

  bool get canWrite =>
      !_closed &&
      (_kind == CopyResponseKind.copyIn || _kind == CopyResponseKind.copyBoth);

  Future<void> init() async {
    final response = await _connector.executeCopyCommand(_copyCommand);
    _kind = response.kind;
  }

  /// Reads the next raw COPY data chunk, or null when COPY output is complete.
  Future<Uint8List?> read() async {
    _throwIfClosed();
    if (!canRead) {
      throw StateError('COPY operation is not readable');
    }

    final packet = await _connector.readCopyDataPacket();
    if (packet == null) {
      await _connector.awaitCopyComplete();
      _completed = true;
      _close(reusable: true);
      return null;
    }

    _bytesTransferred += packet.length;
    _onProgress?.call(_bytesTransferred);
    return packet;
  }

  /// Reads all remaining COPY output chunks into a single byte list.
  Future<Uint8List> readAllBytes() async {
    final builder = BytesBuilder(copy: false);
    while (true) {
      final chunk = await read();
      if (chunk == null) {
        return builder.takeBytes();
      }
      builder.add(chunk);
    }
  }

  /// Reads all remaining COPY output as text.
  Future<String> readAsString({Encoding encoding = utf8}) async {
    return encoding.decode(await readAllBytes());
  }

  /// Writes a raw COPY data chunk.
  Future<void> write(List<int> data) async {
    _throwIfClosed();
    if (!canWrite) {
      throw StateError('COPY operation is not writable');
    }

    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    await _connector.writeCopyData(bytes);
    _bytesTransferred += bytes.length;
    _onProgress?.call(_bytesTransferred);
  }

  /// Writes text to COPY using [encoding].
  Future<void> writeString(String data, {Encoding encoding = utf8}) {
    return write(encoding.encode(data));
  }

  /// Writes all chunks from [stream] to COPY.
  Future<void> writeStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      await write(chunk);
    }
  }

  /// Completes a COPY FROM STDIN operation.
  Future<void> complete() async {
    _throwIfClosed();
    if (!canWrite) {
      throw StateError('COPY operation is not writable');
    }

    await _connector.writeCopyDone();
    await _connector.awaitCopyComplete();
    _completed = true;
    _close(reusable: true);
  }

  /// Cancels a COPY FROM STDIN operation. The physical connector is not reused.
  Future<void> cancel([String message = 'Cancelled by user']) async {
    if (_closed) {
      return;
    }

    if (canWrite) {
      await _connector.writeCopyFail(message);
    }
    _completed = true;
    _close(reusable: false);
  }

  Future<void> dispose() async {
    if (_closed) {
      return;
    }
    if (!_completed && canWrite) {
      await cancel();
      return;
    }
    _close(reusable: _completed);
  }

  void _throwIfClosed() {
    if (_closed) {
      throw StateError('COPY operation has already ended');
    }
  }

  void _close({required bool reusable}) {
    if (_closed) {
      return;
    }
    _closed = true;
    _onClosed(reusable);
  }
}
