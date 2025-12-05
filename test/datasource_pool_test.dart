import 'dart:io';

import 'package:dpgsql/dpgsql.dart';
import 'package:test/test.dart';

void main() {
  test('NpgsqlDataSource pools connections', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;

    int connectionCount = 0;

    server.listen((client) {
      connectionCount++;
      client.listen((chunk) {
        // Handshake
        if (chunk.length > 8 && chunk[0] == 0) {
          final authOk = [0x52, 0, 0, 0, 8, 0, 0, 0, 0];
          final ready = [0x5A, 0, 0, 0, 5, 0x49];
          client.add([...authOk, ...ready]);
        }
        // Terminate 'X'
        if (chunk.isNotEmpty && chunk[0] == 88) {
          client.close();
        }
      });
    });

    final dataSource = NpgsqlDataSource('Host=localhost; Port=$port');

    // 1. Open first connection
    final conn1 = await dataSource.openConnection();
    expect(conn1.state, ConnectionState.open);
    expect(connectionCount, 1);

    // 2. Close first connection (returns to pool)
    await conn1.close();
    expect(conn1.state, ConnectionState.closed);

    // 3. Open second connection (should reuse)
    final conn2 = await dataSource.openConnection();
    expect(conn2.state, ConnectionState.open);
    expect(connectionCount, 1); // Should still be 1 if reused

    // 4. Open third connection (should create new, as pool is empty)
    final conn3 = await dataSource.openConnection();
    expect(conn3.state, ConnectionState.open);
    expect(connectionCount, 2);

    await conn2.close();
    await conn3.close();

    await dataSource.dispose();
    await server.close();
  });
}
