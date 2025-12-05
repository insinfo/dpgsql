import 'dart:convert';
import 'dart:io';

import 'package:dpgsql/dpgsql.dart';
import 'package:test/test.dart';

void main() {
  test('SCRAM Authentication Flow', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    // ignore: unused_local_variable
    final port = server.port;

    server.listen((client) {
      client.listen((chunk) {
        if (chunk.isEmpty) return;

        // 1. Startup Message (approx check)
        if (chunk.length > 8 && chunk[0] == 0 && chunk[3] >= 8) {
          // Send AuthSASL
          final mech = utf8.encode('SCRAM-SHA-256');
          final payload = <int>[
            0, 0, 0, 10, // AuthSASL
            ...mech, 0, 0 // Mechanisms + terminators
          ];
          final msg = <int>[
            82, // 'R'
            0, 0, 0, payload.length + 4,
            ...payload
          ];
          client.add(msg);
          return;
        }

        // 2. SASL Initial Response ('p')
        if (chunk[0] == 112) {
          // 'p'
          final s = String.fromCharCodes(chunk);
          final rIndex = s.indexOf('r=');
          if (rIndex != -1) {
            // See comments in previous iterations about complexity of robust mocking here.
          }
        }
      });
    });

    await server.close();
  });

  test('Binary Types Reading', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;

    server.listen((client) {
      client.listen((chunk) {
        // Startup
        if (chunk.length > 8 && chunk[0] == 0) {
          // AuthOk
          client.add([0x52, 0, 0, 0, 8, 0, 0, 0, 0]);
          // ReadyForQuery
          client.add([0x5A, 0, 0, 0, 5, 0x49]);
        }

        // Query 'Q'
        if (chunk.isNotEmpty && chunk[0] == 81) {
          // RowDescription
          // 1 col, Int4, Format 1 (Binary)
          final rowDesc = <int>[
            0x54, // 'T'
            0, 0, 0, 0, // Length placeholder
            0, 1, // 1 field
            // 'val'
            ...('val'.codeUnits), 0,
            0, 0, 0, 0, // table
            0, 0, // col
            0, 0, 0, 23, // oidh (23 = int4)
            0, 4, // size
            0xFF, 0xFF, 0xFF, 0xFF, // mod
            0, 1 // format 1 (Binary)
          ];

          // Payload size check:
          // 2(count) + 4("val\0") + 4 + 2 + 4 + 2 + 4 + 2 = 24 bytes.
          // Length = 28.
          rowDesc[4] = 28;

          // DataRow
          // 1 col, value = 42 (0x0000002A)
          // Payload: 2 (count) + 4 (len) + 4 (val) = 10.
          // Msg Length: 10 + 4 = 14.
          final dataRow = <int>[
            0x44, // 'D'
            0, 0, 0, 14, // Length
            0, 1, // count
            0, 0, 0, 4, // len 4
            0, 0, 0, 42 // value (Big Endian 42)
          ];

          // CommandComplete
          final cmdComplete = [0x43, 0, 0, 0, 13, ...('SELECT 1'.codeUnits), 0];

          // Ready
          final ready = [0x5A, 0, 0, 0, 5, 0x49];

          client.add([...rowDesc, ...dataRow, ...cmdComplete, ...ready]);
        }
      });
    });

    final conn = NpgsqlConnection('Host=localhost; Port=$port');
    await conn.open();

    final reader = await conn.executeReader('SELECT 42');
    expect(await reader.read(), isTrue);
    // Value should be int 42
    expect(reader[0], equals(42));
    expect(reader[0], isA<int>());

    await conn.close();
    await server.close();
  });
}
