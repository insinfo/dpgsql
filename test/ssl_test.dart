import 'dart:io';
import 'dart:typed_data';

import 'package:dpgsql/dpgsql.dart';
import 'package:test/test.dart';

void main() {
  test('SslMode.require throws if server denies SSL', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;

    server.listen((client) {
      client.listen((chunk) {
        // Check for SSLRequest (Length 8, Code 80877103)
        if (chunk.length >= 8) {
          final bd = ByteData.sublistView(Uint8List.fromList(chunk));
          if (bd.getInt32(0) == 8 && bd.getInt32(4) == 80877103) {
            // Send 'N'
            client.add([78]); // 'N'
            return;
          }
        }
      });
    });

    final conn =
        NpgsqlConnection('Host=localhost; Port=$port; SSL Mode=Require');

    try {
      await conn.open();
      fail('Should have thrown PostgresException');
    } catch (e) {
      expect(e, isA<PostgresException>());
      expect((e as PostgresException).messageText,
          contains('does not support SSL'));
    }

    await conn.close();
    await server.close();
  });

  test('SslMode.prefer proceeds if server denies SSL', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;

    server.listen((client) {
      client.listen((chunk) {
        // Check for SSLRequest
        if (chunk.length >= 8) {
          final bd = ByteData.sublistView(Uint8List.fromList(chunk));
          if (bd.getInt32(0) == 8 && bd.getInt32(4) == 80877103) {
            // Send 'N'
            client.add([78]); // 'N'
            return;
          }
        }

        // Handle Startup Message (Length > 8, Protocol 3.0)
        if (chunk.length > 8) {
          // Startup is usually [Len, 0, 3, 0, ...]
          // But if we already consumed SSLRequest, this is a new chunk?
          // The client sends Startup immediately after receiving 'N'.

          // Just send AuthOk and ReadyForQuery to simulate success
          if (chunk[0] != 80 && chunk.length > 8) {
            // Not 'P' (Password) etc.
            final authOk = [0x52, 0, 0, 0, 8, 0, 0, 0, 0];
            final ready = [0x5A, 0, 0, 0, 5, 0x49];
            client.add([...authOk, ...ready]);
          }
        }
      });
    });

    final conn =
        NpgsqlConnection('Host=localhost; Port=$port; SSL Mode=Prefer');

    await conn.open();
    expect(conn.state, ConnectionState.open);
    await conn.close();
    await server.close();
  });
}
