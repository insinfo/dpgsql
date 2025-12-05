import 'dart:async';
import 'dart:typed_data';
import 'internal/npgsql_connector.dart';
import 'postgres_exception.dart';
import 'protocol/backend_messages.dart'; // For DataFormat? Or exceptions
import 'io/binary_input.dart';

/// Provides an API for engaging in a binary COPY TO STDOUT operation.
/// Porting NpgsqlBinaryExporter.cs
class NpgsqlBinaryExporter {
  NpgsqlBinaryExporter(this._connector, this._copyCommand);

  final NpgsqlConnector _connector;
  final String _copyCommand;
  bool _isDisposed = false;
  late _CopyStreamBinaryInput _input;

  static final Uint8List _signature =
      Uint8List.fromList([80, 71, 67, 79, 80, 89, 10, 255, 13, 10, 0]);

  Future<void> init() async {
    // 1. Send COPY command
    final msg = await _connector.executeCopyCommand(_copyCommand);
    if (msg.kind != CopyResponseKind.copyOut) {
      throw PostgresException(
          severity: 'ERROR',
          invariantSeverity: 'ERROR',
          sqlState: '0A000',
          messageText: 'Unexpected CopyResponseKind for Exporter: ${msg.kind}');
    }

    // 2. Setup Input Stream
    _input = _CopyStreamBinaryInput(_connector);

    // 3. Read Header
    // PGCOPY\n\377\r\n\0 + Flags(0) + Ext(0)
    await _input.ensureBytes(11 + 4 + 4);

    final sig = _input.readBytes(11);
    for (int i = 0; i < 11; i++) {
      if (sig[i] != _signature[i]) throw Exception('Invalid COPY signature');
    }

    final flags = _input.readInt32();
    if (flags != 0) {
      // TODO: Handle OID inclusion flag if needed, usually 0 for standard binary
    }

    final extLength = _input.readInt32();
    await _input.ensureBytes(extLength);
    _input.readBytes(extLength); // Skip extension area
  }

  /// Starts reading a row. Returns number of columns, or -1 if end of data.
  Future<int> startRow() async {
    await _input.ensureBytes(2);
    final count = _input.readInt16();
    if (count == -1) {
      return -1; // Trailer found
    }
    return count;
  }

  /// Reads a value of type T from the current column.
  Future<T?> read<T>() async {
    await _input.ensureBytes(4);
    final len = _input.readInt32();
    if (len == -1) return null; // NULL

    await _input.ensureBytes(len);
    final bytes = Uint8List.fromList(_input.readBytes(len));

    // Resolve handler
    final handler = _connector.typeRegistry.resolveByDartType<T>();
    if (handler != null) {
      return handler.read(bytes);
    }

    // Fallback for special cases not in registry or if T is dynamic
    if (T == dynamic) {
      // We can't guess the type without OID.
      // But maybe we can return bytes?
      // For now, throw.
    }

    throw UnimplementedError(
        'Binary export for type $T not yet supported (no handler found)');
  }

  Future<void> dispose() async {
    if (_isDisposed) return;
    await _connector.awaitCopyComplete();
    _isDisposed = true;
  }
}

class _CopyStreamBinaryInput extends BinaryInput {
  _CopyStreamBinaryInput(this._connector);

  final NpgsqlConnector _connector;
  final List<int> _buffer = [];
  int _offset = 0;
  bool _isDone = false;

  int get _available => _buffer.length - _offset;

  @override
  Future<void> ensureBytes(int count) async {
    if (_available >= count) return;
    if (_isDone) throw Exception('End of COPY data');

    while (_available < count) {
      final packet = await _connector.readCopyDataPacket();
      if (packet == null) {
        _isDone = true;
        if (_available < count) throw Exception('Unexpected end of COPY data');
        return;
      }

      // Append
      // If offset is large, maybe compact?
      if (_offset > 0) {
        _buffer.removeRange(0, _offset);
        _offset = 0;
      }
      _buffer.addAll(packet);
    }
  }

  @override
  int readUint8() {
    if (_available < 1) throw Exception('Buffer empty');
    return _buffer[_offset++];
  }

  @override
  int readInt16() {
    if (_available < 2) throw Exception('Buffer empty');
    final b1 = _buffer[_offset++];
    final b2 = _buffer[_offset++];
    return ((b1 << 8) | b2).toSigned(16); // Big Endian Signed
  }

  @override
  int readInt32() {
    if (_available < 4) throw Exception('Buffer empty');
    final b1 = _buffer[_offset++];
    final b2 = _buffer[_offset++];
    final b3 = _buffer[_offset++];
    final b4 = _buffer[_offset++];
    return ((b1 << 24) | (b2 << 16) | (b3 << 8) | b4).toSigned(32);
  }

  @override
  List<int> readBytes(int length) {
    if (_available < length) throw Exception('Buffer empty');
    final sub = _buffer.sublist(_offset, _offset + length);
    _offset += length;
    return sub;
  }
}
