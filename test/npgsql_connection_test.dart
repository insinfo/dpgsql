import 'dart:io';
import 'dart:typed_data';

import 'package:dpgsql/dpgsql.dart';
import 'package:test/test.dart';

void main() {
  test('NpgsqlConnection opens connection with valid handshake', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;

    // Server logic
    server.listen((client) {
      // 1. Receive Startup (Length + Protocol(4) + Params + 0)
      // Just consume bytes for now or use BinaryInput
      final data = <int>[];
      client.listen((chunk) {
        data.addAll(chunk);
        // Check if we received enough for startup (just rough check)
        if (data.length > 8) {
          // Send AuthOK
          // 'R' + length(8) + 0(code)
          final authOk = [
            0x52, // 'R'
            0, 0, 0, 8,
            0, 0, 0, 0
          ];
          client.add(authOk);

          // Send ReadyForQuery
          // 'Z' + length(5) + 'I'
          final ready = [
            0x5A, // 'Z'
            0, 0, 0, 5,
            0x49 // 'I'
          ];
          client.add(ready);
        }
      });
    });

    final conn = NpgsqlConnection(
        'Host=localhost; Port=$port; Username=postgres; Password=secret');

    expect(conn.state, ConnectionState.closed);

    await conn.open();

    expect(conn.state, ConnectionState.open);

    await conn.close();
    await server.close();
  });

  test('NpgsqlConnection throws PostgresException on ErrorResponse', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;

    server.listen((client) {
      // Wait for startup then send Error
      client.listen((chunk) {
        if (chunk.isNotEmpty) {
          // Send ErrorResponse
          // 'E' + length + Fields + 0
          final S = [0x53] + 'ERROR'.codeUnits + [0];
          final C = [0x43] + '28P01'.codeUnits + [0];
          final M = [0x4D] + 'Auth failed'.codeUnits + [0];
          final body = [...S, ...C, ...M, 0];

          final length = body.length + 4;
          final msg = [0x45, ..._int32(length), ...body];

          client.add(msg);
        }
      });
    });

    final conn = NpgsqlConnection('Host=localhost; Port=$port');

    try {
      await conn.open();
      fail('Should have thrown');
    } on PostgresException catch (e) {
      expect(e.sqlState, '28P01');
      expect(e.severity, 'ERROR');
      expect(e.messageText, 'Auth failed');
    }

    await server.close();
  });
}

List<int> _int32(int value) {
  final bd = ByteData(4)..setInt32(0, value);
  return bd.buffer.asUint8List();
}
