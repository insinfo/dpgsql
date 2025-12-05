import 'dart:typed_data';
import 'internal/npgsql_connector.dart';
import 'postgres_exception.dart';
import 'protocol/backend_messages.dart';

/// Provides an API for engaging in a binary COPY operation.
/// Porting NpgsqlBinaryImporter.cs
class NpgsqlBinaryImporter {
  NpgsqlBinaryImporter(this._connector, this._copyCommand);

  final NpgsqlConnector _connector;
  final String _copyCommand;
  bool _isDisposed = false;

  static final Uint8List _signature =
      Uint8List.fromList([80, 71, 67, 79, 80, 89, 10, 255, 13, 10, 0]);

  Future<void> init() async {
    // 1. Send COPY command
    final msg = await _connector.executeCopyCommand(_copyCommand);
    if (msg.kind != CopyResponseKind.copyIn) {
      throw PostgresException(
          severity: 'ERROR',
          invariantSeverity: 'ERROR',
          sqlState: '0A000',
          messageText: 'Unexpected CopyResponseKind for Importer: ${msg.kind}');
    }
    // 3. Write Header
    // PGCOPY\n\377\r\n\0 + Flags(0) + Ext(0)
    final header = ByteData(19);
    final sig = _signature;
    for (int i = 0; i < sig.length; i++) header.setUint8(i, sig[i]);
    header.setInt32(11, 0); // Flags
    header.setInt32(15, 0); // Extension area length

    await _connector.writeCopyData(header.buffer.asUint8List());
  }

  /// Starts a new row.
  /// Must be called before writing columns.
  /// [numColumns] is the number of columns in this row.
  Future<void> startRow(int numColumns) async {
    final bd = ByteData(2);
    bd.setInt16(0, numColumns);
    await _connector.writeCopyData(bd.buffer.asUint8List());
  }

  /// Writes a value to the current row.
  Future<void> write<T>(T value) async {
    if (value == null) {
      await writeNull();
      return;
    }

    // Resolve handler
    final handler = _connector.typeRegistry.resolveByValue(value);
    if (handler == null) {
      // Fallback to text encoding? Or error?
      // Binary import expects binary data.
      throw UnimplementedError(
          'No handler found for type ${value.runtimeType} in binary import');
    }

    final bytes =
        handler.write(value as dynamic); // dynamic cast for handler generic
    final lenBd = ByteData(4);
    lenBd.setInt32(0, bytes.length);
    await _connector.writeCopyData(lenBd.buffer.asUint8List());
    await _connector.writeCopyData(bytes);
  }

  Future<void> writeNull() async {
    final lenBd = ByteData(4);
    lenBd.setInt32(0, -1);
    await _connector.writeCopyData(lenBd.buffer.asUint8List());
  }

  /// Completes the import operation.
  Future<void> complete() async {
    if (_isDisposed) return;

    // Trailer: -1 (int16)
    final trailer = ByteData(2);
    trailer.setInt16(0, -1);
    await _connector.writeCopyData(trailer.buffer.asUint8List());

    // CopyDone
    await _connector.writeCopyDone();

    // Await CommandComplete
    await _connector.awaitCopyComplete();

    _isDisposed = true;
  }

  /// Closes the importer. If complete() was not called, this rolls back (CopyFail).
  Future<void> close() async {
    if (_isDisposed) return;

    try {
      await _connector.writeCopyFail("Cancelled by user");
    } catch (e) {
      // Ignore
    }
    _isDisposed = true;
  }
}
