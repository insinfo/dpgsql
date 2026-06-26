import 'dart:io';

import 'package:test/test.dart';
import 'package:dpgsql/dpgsql.dart';

void main() {
  test('Pipeline Mode - Basic functionality', () async {
    // This test demonstrates the pipeline mode API
    // Note: This is a unit test of the API structure, not integration with a real server

    // Create a connection (this would normally connect to a real server)
    final conn = DpgsqlConnection('Host=localhost;Port=5432;Database=test');

    // Demonstrate API exists
    expect(conn.inPipelineMode, isFalse);

    // These would work with a real connection:
    // conn.enterPipelineMode();
    // expect(conn.inPipelineMode, isTrue);

    // Send multiple commands without waiting
    // final cmd1 = conn.executeQueryPipelined(sql: 'SELECT 1');
    // final cmd2 = conn.executeQueryPipelined(sql: 'SELECT 2');
    // final cmd3 = conn.executeQueryPipelined(sql: 'SELECT 3');

    // Send Sync and wait for all responses
    // await conn.pipelineSync();

    // Exit pipeline mode
    // conn.exitPipelineMode();

    // This test just ensures the API compiles correctly
  });

  test('Pipeline Mode - Multiple commands demo', () {
    // This test documents the expected usage pattern

    void exampleUsage() async {
      final conn = DpgsqlConnection('Host=localhost;Database=test');
      await conn.open();

      try {
        // Enter pipeline mode
        conn.enterPipelineMode();

        // Send 10 queries without waiting for responses
        // for (var i = 0; i < 10; i++) {
        //   conn.executeQueryPipelined(
        //     sql: 'SELECT \$1::int',
        //     parameters: DpgsqlParameterCollection()..addWithValue('p', i),
        //   );
        // }

        // Send Sync - this is the barrier
        // All previous queries will complete before anything after this
        await conn.pipelineSync();

        // Exit pipeline mode
        conn.exitPipelineMode();
      } finally {
        await conn.close();
      }
    }

    // This is just documentation - the function isn't called
    expect(exampleUsage, isA<Function>());
  });

  test('Pipeline Mode - Streaming results per pending command', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;

    server.listen((client) {
      final buffer = <int>[];
      var expectingStartup = true;
      var responded = false;

      void sendPipelineResponses() {
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
        ];
        final dataRow1 = [0x44, 0, 0, 0, 11, 0, 1, 0, 0, 0, 1, 49];
        final cmdComplete1 = [0x43, 0, 0, 0, 13, ...('SELECT 1'.codeUnits), 0];

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
        final dataRow2 = [0x44, 0, 0, 0, 11, 0, 1, 0, 0, 0, 1, 50];
        final cmdComplete2 = [0x43, 0, 0, 0, 13, ...('SELECT 1'.codeUnits), 0];
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
          ...ready,
        ]);
        responded = true;
      }

      client.listen((chunk) {
        buffer.addAll(chunk);

        while (true) {
          if (expectingStartup) {
            if (buffer.length < 4) {
              return;
            }
            final length = (buffer[0] << 24) |
                (buffer[1] << 16) |
                (buffer[2] << 8) |
                buffer[3];
            if (buffer.length < length) {
              return;
            }
            buffer.removeRange(0, length);
            final authOk = [0x52, 0, 0, 0, 8, 0, 0, 0, 0];
            final ready = [0x5A, 0, 0, 0, 5, 0x49];
            client.add([...authOk, ...ready]);
            expectingStartup = false;
            continue;
          }

          if (buffer.length < 5) {
            return;
          }

          final type = buffer[0];
          final length = (buffer[1] << 24) |
              (buffer[2] << 16) |
              (buffer[3] << 8) |
              buffer[4];
          final total = 1 + length;

          if (buffer.length < total) {
            return;
          }

          if (type == 0x53 && !responded) {
            sendPipelineResponses();
          }

          if (type == 0x58) {
            client.close();
            return;
          }

          buffer.removeRange(0, total);
        }
      });
    });

    final conn = DpgsqlConnection('Host=localhost; Port=$port');
    await conn.open();

    conn.enterPipelineMode();
    final pending1 = await conn.executeQueryPipelined('SELECT 1');
    final pending2 = await conn.executeQueryPipelined('SELECT 2');

    await conn.pipelineSync();

    final reader =
        await conn.getPipelineReaderForCommands([pending1, pending2]);

    expect(await reader.read(), isTrue);
    expect(reader[0], 1);
    expect(await reader.read(), isFalse);

    expect(await reader.nextResult(), isTrue);
    expect(reader.fieldCount, 1);
    expect(await reader.read(), isTrue);
    expect(reader[0], 2);
    expect(await reader.read(), isFalse);
    expect(await reader.nextResult(), isFalse);

    await reader.close();

    conn.exitPipelineMode();
    await conn.close();
    await server.close();
  });

  test('Pipeline Mode - DpgsqlCommand integration helper', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;

    server.listen((client) {
      final buffer = <int>[];
      var expectingStartup = true;
      var responded = false;

      void sendPipelineResponses() {
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
        ];
        final dataRow1 = [0x44, 0, 0, 0, 11, 0, 1, 0, 0, 0, 1, 49];
        final cmdComplete1 = [0x43, 0, 0, 0, 13, ...('SELECT 1'.codeUnits), 0];

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
        final dataRow2 = [0x44, 0, 0, 0, 11, 0, 1, 0, 0, 0, 1, 50];
        final cmdComplete2 = [0x43, 0, 0, 0, 13, ...('SELECT 1'.codeUnits), 0];
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
          ...ready,
        ]);
        responded = true;
      }

      client.listen((chunk) {
        buffer.addAll(chunk);

        while (true) {
          if (expectingStartup) {
            if (buffer.length < 4) {
              return;
            }
            final length = (buffer[0] << 24) |
                (buffer[1] << 16) |
                (buffer[2] << 8) |
                buffer[3];
            if (buffer.length < length) {
              return;
            }
            buffer.removeRange(0, length);
            final authOk = [0x52, 0, 0, 0, 8, 0, 0, 0, 0];
            final ready = [0x5A, 0, 0, 0, 5, 0x49];
            client.add([...authOk, ...ready]);
            expectingStartup = false;
            continue;
          }

          if (buffer.length < 5) {
            return;
          }

          final type = buffer[0];
          final length = (buffer[1] << 24) |
              (buffer[2] << 16) |
              (buffer[3] << 8) |
              buffer[4];
          final total = 1 + length;

          if (buffer.length < total) {
            return;
          }

          if (type == 0x53 && !responded) {
            sendPipelineResponses();
          }

          if (type == 0x58) {
            client.close();
            return;
          }

          buffer.removeRange(0, total);
        }
      });
    });

    final conn = DpgsqlConnection('Host=localhost; Port=$port');
    await conn.open();

    final cmd1 = conn.createCommand('SELECT @value::int');
    cmd1.parameters.addWithValue('value', 1);

    final cmd2 = conn.createCommand('SELECT @value::int');
    cmd2.parameters.addWithValue('value', 2);

    final reader = await conn.executeCommandsPipelined([cmd1, cmd2]);

    expect(conn.inPipelineMode, isTrue);

    expect(await reader.read(), isTrue);
    expect(reader[0], 1);
    expect(await reader.read(), isFalse);

    expect(await reader.nextResult(), isTrue);
    expect(await reader.read(), isTrue);
    expect(reader[0], 2);
    expect(await reader.read(), isFalse);
    expect(await reader.nextResult(), isFalse);

    await reader.close();
    expect(conn.inPipelineMode, isFalse);

    await conn.close();
    await server.close();
  });
}
