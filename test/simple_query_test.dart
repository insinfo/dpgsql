import 'dart:io';

import 'package:dpgsql/dpgsql.dart';
import 'package:test/test.dart';

void main() {
  test('NpgsqlCommand executes Simple Query and reads results', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;

    server.listen((client) {
      client.listen((chunk) {
        // Just mocking responses blindly based on expected flow
        // final str = String.fromCharCodes(chunk);

        // Handshake
        if (chunk.length > 8 && chunk[0] == 0) {
          // Startup
          final authOk = [0x52, 0, 0, 0, 8, 0, 0, 0, 0];
          final ready = [0x5A, 0, 0, 0, 5, 0x49];
          client.add([...authOk, ...ready]);
        }

        // Query 'Q' check
        if (chunk.isNotEmpty && chunk[0] == 81) {
          // 'Q'
          // Send RowDescription (1 col 'test')
          // 'T' + len + count(1) + field...
          final rowDesc = [
            0x54,
            0, 0, 0, 27, // length (estimado: 4 + 2 + (name=5+1 + 18)) = 30?
            0, 1, // count 1
            ...('test'.codeUnits), 0, // name
            0, 0, 0, 0, // table oid
            0, 0, // attr num
            0, 0, 0, 23, // type oid (int4)
            0, 4, // size 4
            0xFF, 0xFF, 0xFF, 0xFF, // modifier -1
            0, 0 // binary (text=0)
          ];
          // Adjust length: 4 + 2 + 5 + 4 + 2 + 4 + 2 + 4 + 2 = 29
          // 'test\0' is 5 bytes.
          // RowDesc fields: name(s) + tableoid(4) + attr(2) + type(4) + size(2) + mod(4) + fmt(2) = S + 18
          // Name 'test' + \0 = 5 bytes. Total field = 23 bytes.
          // Header: Type(1) + Len(4) + Count(2). Len includes itself.
          // Len = 4 + 2 + 23 = 29.

          // Fix length in array above manually: 0, 0, 0, 29
          rowDesc[4] = 29;

          // Send DataRow ('1')
          // 'D' + len + count(1) + len(1) + '1'
          final dataRow = [
            0x44,
            0, 0, 0, 11, // len: 4 + 2 + 4 + 1 = 11
            0, 1, // count 1
            0, 0, 0, 1, // col len 1
            49 // '1'
          ];

          // Send CommandComplete "SELECT 1"
          final cmdComplete = [
            0x43,
            0, 0, 0, 13, // 4 + "SELECT 1\0" (9) = 13
            ...('SELECT 1'.codeUnits), 0
          ];

          // Send ReadyForQuery
          final ready = [0x5A, 0, 0, 0, 5, 0x49];

          client.add([...rowDesc, ...dataRow, ...cmdComplete, ...ready]);
        }
      });
    });

    final conn = NpgsqlConnection('Host=localhost; Port=$port');
    await conn.open();

    final cmd = NpgsqlCommand('SELECT 1', conn);
    final reader = await cmd.executeReader();

    expect(reader.fieldCount, 1);
    expect(await reader.read(), isTrue);
    expect(reader[0], 1);
    expect(reader['test'], 1);
    expect(await reader.read(), isFalse);

    await conn.close();
    await server.close();
  });
}
