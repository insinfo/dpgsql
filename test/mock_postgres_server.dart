import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';

/// A Mock PostgreSQL Server for testing replication connections.
class MockPostgresServer {
  ServerSocket? _server;
  final int port;
  final List<Socket> _clients = [];
  final StreamController<List<int>> _clientDataController =
      StreamController<List<int>>.broadcast();

  Stream<List<int>> get clientData => _clientDataController.stream;

  MockPostgresServer(this.port);

  Future<void> start() async {
    _server = await ServerSocket.bind('localhost', port);
    _server!.listen(_handleClient);
    print('Mock Server listening on $port');
  }

  void _handleClient(Socket client) {
    _clients.add(client);
    client.listen(
      (data) {
        _clientDataController.add(data);
        _processClientData(client, data);
      },
      onError: (e) => print('Client error: $e'),
      onDone: () {
        _clients.remove(client);
      },
    );
  }

  final List<int> _buffer = [];

  void _processClientData(Socket client, List<int> data) {
    _buffer.addAll(data);

    // Simple state machine for handshake
    if (_buffer.length >= 8) {
      final bd = ByteData.sublistView(Uint8List.fromList(_buffer));
      final len = bd.getInt32(0);
      final protocol = bd.getInt32(4);

      if (protocol == 80877103) {
        // SSL Request
        client.add([78]); // 'N'
        _buffer.removeRange(0, 8);
        return;
      }

      if (protocol == 196608) {
        // Startup Message 3.0
        if (_buffer.length >= len) {
          // Parse params if needed
          _buffer.removeRange(0, len);

          // Send Auth OK
          final authOk = ByteData(9);
          authOk.setUint8(0, 82); // 'R'
          authOk.setInt32(1, 8); // Length
          authOk.setInt32(5, 0); // AuthOk
          client.add(authOk.buffer.asUint8List());

          // Send ReadyForQuery
          final ready = ByteData(6);
          ready.setUint8(0, 90); // 'Z'
          ready.setInt32(1, 5); // Length
          ready.setUint8(5, 73); // 'I'
          client.add(ready.buffer.asUint8List());
          return;
        }
      }

      // Query (Q)
      if (_buffer.isNotEmpty && _buffer[0] == 81) {
        // 'Q'
        if (_buffer.length >= len + 1) {
          // Type + Len + Body
          // Actually, Q message format: 'Q' + int32 len + string query + \0
          // We just read simplisticly here.
          // Identify START_REPLICATION
          final str = utf8.decode(_buffer.sublist(5, _buffer.length - 1));
          _buffer.clear(); // Consumed

          if (str.startsWith("START_REPLICATION")) {
            // Send CopyBothResponse
            final copyResponse =
                ByteData(5 + 1 + 2); // 'W' + len + 0 + numFormats(0)
            // CopyBothResponse: 'W', int32 len, int8 0 (overall format), int16 numColumnFormats(0)
            copyResponse.setUint8(0, 87); // 'W'
            copyResponse.setInt32(1, 4 + 1 + 2); // 7
            copyResponse.setInt8(5, 0);
            copyResponse.setInt16(6, 0);
            client.add(copyResponse.buffer.asUint8List());

            // Start streaming fake WAL
            _sendReplicationData(client);
          }
          return;
        }
      }

      // StandbyStatusUpdate (d) inside CopyData (d is frontend message, c is backend message CopyData)
      // Frontend sends CopyData(d) with 'd' payload.
      // We just log it via stream.
    }
  }

  void _sendReplicationData(Socket client) async {
    await Future.delayed(Duration(milliseconds: 100));

    // 1. Send Begin
    // 'd' + len + 'w' + header + BeginMessage
    // Simplified:

    // Begin Message Body: 'B' + Int64 LSN + Int64 Time + Int32 Xid
    // We wrap it in 'w' (WALData)

    // Let's just send KeepAlive first to trigger ack.
    // 'd' (CopyData)
    // Payload: 'k' + Int64 EndWal + Int64 Time + Byte1 ReplyRequested

    final keepAlivePayload = ByteData(1 + 8 + 8 + 1);
    keepAlivePayload.setUint8(0, 0x6b); // 'k'
    keepAlivePayload.setInt64(1, 1000); // EndWal
    keepAlivePayload.setInt64(9, DateTime.now().microsecondsSinceEpoch); // Time
    keepAlivePayload.setUint8(17, 1); // ReplyRequested

    _sendCopyData(client, keepAlivePayload.buffer.asUint8List());
  }

  void _sendCopyData(Socket client, Uint8List payload) {
    final len = 4 + payload.length;
    final msg = ByteData(1 + len);
    msg.setUint8(0, 0x64); // 'd'
    msg.setInt32(1, len);
    // Fill payload
    for (int i = 0; i < payload.length; i++) {
      msg.setUint8(5 + i, payload[i]);
    }
    client.add(msg.buffer.asUint8List());
  }

  Future<void> stop() async {
    for (final c in _clients) {
      c.destroy();
    }
    await _server?.close();
  }
}
