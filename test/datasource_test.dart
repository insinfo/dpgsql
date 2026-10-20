import 'dart:io';

import 'package:dpgsql/dpgsql.dart';
import 'package:test/test.dart';

void main() {
  test('DpgsqlDataSource reuses connections', () async {
    int connectionCount = 0;

    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;

    server.listen((client) {
      connectionCount++;
      client.listen((chunk) {
        _answerSimpleQuery(client, chunk);
        // Mock Handshake
        if (chunk.length > 8 && chunk[0] == 0) {
          // Startup
          final authOk = [0x52, 0, 0, 0, 8, 0, 0, 0, 0];
          final ready = [0x5A, 0, 0, 0, 5, 0x49];
          client.add([...authOk, ...ready]);
        }
      });
    });

    final dataSource = DpgsqlDataSource('Host=localhost; Port=$port');

    // First connection
    final conn1 = await dataSource.openConnection();
    expect(connectionCount, 1);
    await conn1.close();

    // Second connection (should reuse)
    final conn2 = await dataSource.openConnection();
    expect(connectionCount, 1); // Connection count should still be 1 if reused
    await conn2.close();

    await server.close();
  });
}

/// Answers a simple query ('Q') with CommandComplete and ReadyForQuery, as a
/// server does: the pool resets a reused connection with one on checkout.
void _answerSimpleQuery(Socket client, List<int> chunk) {
  if (chunk.isEmpty || chunk[0] != 0x51) return;
  const tag = [0x53, 0x45, 0x54, 0]; // 'SET'
  client.add([
    0x43, 0, 0, 0, 4 + tag.length, ...tag, // CommandComplete
    0x5A, 0, 0, 0, 5, 0x49, // ReadyForQuery (idle)
  ]);
}
