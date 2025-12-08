import 'dart:typed_data';
import 'binary_output.dart';

/// Buffered write queue for batching protocol messages before flushing.
///
/// This reduces the number of socket writes by accumulating multiple
/// messages in memory before sending them all at once.
class WriteBuffer {
  WriteBuffer({
    this.maxBufferSize = 8192, // 8KB default
    required BinaryOutput output,
  }) : _output = output;

  final int maxBufferSize;
  final BinaryOutput _output;
  final List<Uint8List> _pendingMessages = [];
  int _bufferedBytes = 0;

  /// Add a message to the buffer without flushing.
  void enqueue(Uint8List message) {
    _pendingMessages.add(message);
    _bufferedBytes += message.length;
  }

  /// Flag indicating whether there are messages aguardando flush.
  bool get hasPending => _pendingMessages.isNotEmpty;

  /// Check if buffer should be flushed based on size.
  bool get shouldFlush => _bufferedBytes >= maxBufferSize;

  /// Number of messages currently buffered.
  int get messageCount => _pendingMessages.length;

  /// Total bytes buffered.
  int get bufferedBytes => _bufferedBytes;

  /// Write all buffered messages to the output and flush.
  Future<void> flush() async {
    if (_pendingMessages.isEmpty) return;

    // Write all messages
    for (final message in _pendingMessages) {
      _output.writeBytes(message);
    }

    // Flush to socket
    await _output.flush();

    // Clear buffer
    _pendingMessages.clear();
    _bufferedBytes = 0;
  }

  /// Write all buffered messages without flushing the socket.
  /// Useful for pipeline mode where explicit flush control is needed.
  void writeToOutput() {
    if (_pendingMessages.isEmpty) return;

    for (final message in _pendingMessages) {
      _output.writeBytes(message);
    }

    _pendingMessages.clear();
    _bufferedBytes = 0;
  }

  /// Clear buffer without writing.
  void clear() {
    _pendingMessages.clear();
    _bufferedBytes = 0;
  }

  /// Auto-flush if buffer exceeds threshold.
  Future<void> flushIfNeeded() async {
    if (shouldFlush) {
      await flush();
    }
  }

  /// Get buffer usage as percentage.
  double get usagePercent {
    if (maxBufferSize == 0) return 0.0;
    return (_bufferedBytes / maxBufferSize) * 100;
  }
}

/// Extension to PostgresMessageWriter for buffered writes.
class BufferedMessageWriter {
  BufferedMessageWriter({
    required BinaryOutput output,
    int bufferSize = 8192,
    this.autoFlush = true,
  })  : _buffer = WriteBuffer(maxBufferSize: bufferSize, output: output),
        _output = output;

  final WriteBuffer _buffer;
  final BinaryOutput _output;
  final bool autoFlush;

  /// Write a message to the buffer (not immediately flushed).
  void writeMessageBuffered(
    int typeCode,
    void Function(MemoryBinaryOutput body) buildBody,
  ) {
    final body = MemoryBinaryOutput(initialCapacity: 256);
    buildBody(body);

    final payload = body.toUint8List();
    final totalLength = payload.length + 4; // +4 for the length field itself

    // Build complete message
    final message = MemoryBinaryOutput(initialCapacity: totalLength + 1);
    message.writeUint8(typeCode);
    message.writeInt32(totalLength);
    message.writeBytes(payload);

    _buffer.enqueue(message.toUint8List());
  }

  /// Write message directly to output (bypassing buffer).
  Future<void> writeMessageDirect(
    int typeCode,
    void Function(MemoryBinaryOutput body) buildBody,
  ) async {
    final body = MemoryBinaryOutput(initialCapacity: 256);
    buildBody(body);

    final payload = body.toUint8List();
    final totalLength = payload.length + 4;

    _output.writeUint8(typeCode);
    _output.writeInt32(totalLength);
    _output.writeBytes(payload);

    await _output.flush();
  }

  /// Flush buffered messages.
  Future<void> flush() => _buffer.flush();

  /// Flush if buffer exceeds threshold.
  Future<void> flushIfNeeded() => _buffer.flushIfNeeded();

  /// Get buffer statistics.
  Map<String, dynamic> get bufferStats => {
        'messageCount': _buffer.messageCount,
        'bufferedBytes': _buffer.bufferedBytes,
        'maxBufferSize': _buffer.maxBufferSize,
        'usagePercent': _buffer.usagePercent.toStringAsFixed(1),
        'shouldFlush': _buffer.shouldFlush,
      };

  /// Clear buffer.
  void clearBuffer() => _buffer.clear();
}
