import 'dart:io';

import 'package:dpgsql/dpgsql.dart';
import 'package:test/test.dart';

void main() {
  test('NpgsqlBatch executes multiple commands in pipeline', () async {
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

        // Extended Query: Parse 'P'
        if (chunk.isNotEmpty && chunk[0] == 80) {
          // We expect multiple commands pipelined.
          // For simplicity, we just dump all responses at once when we see the first 'P'.
          // In a real server, it would process them sequentially.

          // Response for Command 1 (SELECT 1)
          final parseComplete = [0x31, 0, 0, 0, 4];
          final bindComplete = [0x32, 0, 0, 0, 4];
          final rowDesc1 = [
            0x54,
            0,
            0,
            0,
            29,
            0,
            1,
            ...('col1'.codeUnits),
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
          ]; // int4
          final dataRow1 = [
            0x44, 0, 0, 0, 11, 0, 1, 0, 0, 0, 1, 49 // '1'
          ];
          final cmdComplete1 = [
            0x43,
            0,
            0,
            0,
            13,
            ...('SELECT 1'.codeUnits),
            0
          ];

          // Response for Command 2 (SELECT 2)
          // ParseComplete, BindComplete, RowDescription, DataRow, CommandComplete
          final rowDesc2 = [
            0x54,
            0,
            0,
            0,
            29,
            0,
            1,
            ...('col2'.codeUnits),
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
          final dataRow2 = [
            0x44, 0, 0, 0, 11, 0, 1, 0, 0, 0, 1, 50 // '2'
          ];
          final cmdComplete2 = [
            0x43,
            0,
            0,
            0,
            13,
            ...('SELECT 1'.codeUnits),
            0
          ];

          final ready = [0x5A, 0, 0, 0, 5, 0x49];

          client.add([
            ...parseComplete,
            ...bindComplete,
            ...rowDesc1,
            ...dataRow1,
            ...cmdComplete1,
            ...parseComplete,
            ...bindComplete,
            ...rowDesc2,
            ...dataRow2,
            ...cmdComplete2,
            ...ready
          ]);
        }
      });
    });

    final conn = NpgsqlConnection('Host=localhost; Port=$port');
    await conn.open();

    final batch = conn.createBatch();
    batch.createBatchCommand('SELECT 1');
    batch.createBatchCommand('SELECT 2');

    final reader = await batch.executeReader();

    // Result 1
    expect(reader.fieldCount, 1);
    expect(await reader.read(), isTrue);
    expect(reader[0], 1);
    expect(await reader.read(), isFalse);

    // Result 2
    expect(await reader.nextResult(), isTrue);
    expect(reader.fieldCount, 1);
    expect(await reader.read(), isTrue);
    expect(reader[0], 2);
    expect(await reader.read(), isFalse);

    // End
    expect(await reader.nextResult(), isFalse);

    await conn.close();
    await server.close();
  });
}
