import 'dart:io';

import 'package:dpgsql/dpgsql.dart';
import 'package:test/test.dart';

void main() {
  test('NpgsqlCommand executes Extended Query with Parameters', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;

    server.listen((client) {
      client.listen((chunk) {
        // Just mocking responses blindly based on expected flow

        // Handshake
        if (chunk.length > 8 && chunk[0] == 0) {
          // Startup
          final authOk = [0x52, 0, 0, 0, 8, 0, 0, 0, 0];
          final ready = [0x5A, 0, 0, 0, 5, 0x49];
          client.add([...authOk, ...ready]);
        }

        // Extended Query: Parse 'P'
        if (chunk.isNotEmpty && chunk[0] == 80) {
          // 'P'
          // Assume full flow: Parse -> Bind -> Describe -> Execute -> Sync

          // ParseComplete
          final parseComplete = [0x31, 0, 0, 0, 4];

          // BindComplete
          final bindComplete = [0x32, 0, 0, 0, 4];

          // RowDescription
          final rowDesc = [
            0x54,
            0,
            0,
            0,
            29,
            0,
            1,
            ...('test'.codeUnits),
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            23,
            0,
            4,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0,
            0
          ];

          // DataRow
          final dataRow = [
            0x44,
            0, 0, 0, 11,
            0, 1,
            0, 0, 0, 1,
            49 // '1'
          ];

          // CommandComplete
          final cmdComplete = [0x43, 0, 0, 0, 13, ...('SELECT 1'.codeUnits), 0];

          // ReadyForQuery
          final ready = [0x5A, 0, 0, 0, 5, 0x49];

          client.add([
            ...parseComplete,
            ...bindComplete,
            ...rowDesc,
            ...dataRow,
            ...cmdComplete,
            ...ready
          ]);
        }
      });
    });

    final conn = NpgsqlConnection('Host=localhost; Port=$port');
    await conn.open();

    final cmd = NpgsqlCommand('SELECT \$1', conn);
    cmd.parameters.addWithValue('p1', 1);

    final reader = await cmd.executeReader();

    expect(reader.fieldCount, 1);
    expect(await reader.read(), isTrue);
    expect(reader[0], '1');
    expect(await reader.read(), isFalse);

    await conn.close();
    await server.close();
  });
}
