import 'dart:io';

import 'package:dpgsql/dpgsql.dart';
import 'package:test/test.dart';

void main() {
  test('NpgsqlTransaction executes commands', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;

    server.listen((client) {
      client.listen((chunk) {
        // Handshake
        if (chunk.length > 8 && chunk[0] == 0) {
          final authOk = [0x52, 0, 0, 0, 8, 0, 0, 0, 0];
          final ready = [0x5A, 0, 0, 0, 5, 0x49];
          client.add([...authOk, ...ready]);
        }

        // Query 'Q'
        if (chunk.isNotEmpty && chunk[0] == 81) {
          final query =
              String.fromCharCodes(chunk.sublist(5, chunk.length - 1));
          // print('Server received: $query');

          final cmdComplete = [
            0x43,
            0,
            0,
            0,
            13,
            ...('SELECT 1'.codeUnits),
            0
          ]; // Generic completion
          final ready = [0x5A, 0, 0, 0, 5, 0x54]; // Ready in Transaction 'T'

          if (query == 'COMMIT' || query == 'ROLLBACK') {
            ready[5] = 0x49; // Idle 'I'
          }

          client.add([...cmdComplete, ...ready]);
        }
      });
    });

    final conn = NpgsqlConnection('Host=localhost; Port=$port');
    await conn.open();

    final tx = await conn.beginTransaction();
    await tx.save('sp1');
    await tx.rollbackTo('sp1');
    await tx.release('sp1');
    await tx.commit();

    await conn.close();
    await server.close();
  });
}
