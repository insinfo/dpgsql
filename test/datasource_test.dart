import 'dart:io';

import 'package:dpgsql/dpgsql.dart';
import 'package:test/test.dart';

void main() {
  test('NpgsqlDataSource reuses connections', () async {
    int connectionCount = 0;

    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;

    server.listen((client) {
      connectionCount++;
      client.listen((chunk) {
        // Mock Handshake
        if (chunk.length > 8 && chunk[0] == 0) {
          // Startup
          final authOk = [0x52, 0, 0, 0, 8, 0, 0, 0, 0];
          final ready = [0x5A, 0, 0, 0, 5, 0x49];
          client.add([...authOk, ...ready]);
        }
      });
    });

    final dataSource = NpgsqlDataSource('Host=localhost; Port=$port');

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
