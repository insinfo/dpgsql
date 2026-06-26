import 'dart:async';
import 'dart:io';

import 'package:dpgsql/dpgsql.dart';
import 'package:test/test.dart';

void main() {
  test('DpgsqlConnectionStringBuilder parses pool options', () {
    final builder = DpgsqlConnectionStringBuilder(
      'Host=localhost;Minimum Pool Size=2;Maximum Pool Size=8;'
      'Timeout=3;Connection Idle Lifetime=7;Connection Lifetime=11;'
      'Connection Pruning Interval=13',
    );

    expect(builder.minPoolSize, 2);
    expect(builder.maxPoolSize, 8);
    expect(builder.timeout, const Duration(seconds: 3));
    expect(builder.connectionIdleLifetime, const Duration(seconds: 7));
    expect(builder.connectionLifetime, const Duration(seconds: 11));
    expect(builder.connectionPruningInterval, const Duration(seconds: 13));
  });

  test('DpgsqlDataSource pools connections', () async {
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

    final dataSource = DpgsqlDataSource('Host=localhost; Port=$port');

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

  test('DpgsqlDataSource waits when maximum pool size is reached', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;

    var connectionCount = 0;
    server.listen((client) {
      connectionCount++;
      client.listen((chunk) {
        if (chunk.length > 8 && chunk[0] == 0) {
          final authOk = [0x52, 0, 0, 0, 8, 0, 0, 0, 0];
          final ready = [0x5A, 0, 0, 0, 5, 0x49];
          client.add([...authOk, ...ready]);
        }
      });
    });

    final dataSource = DpgsqlDataSource(
      'Host=localhost; Port=$port; Maximum Pool Size=1; Timeout=5',
    );

    final conn1 = await dataSource.openConnection();
    var secondCompleted = false;
    final secondFuture = dataSource.openConnection().then((conn) {
      secondCompleted = true;
      return conn;
    });

    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(secondCompleted, isFalse);
    expect(dataSource.busyCount, 1);
    expect(dataSource.waitingCount, 1);

    await conn1.close();
    final conn2 = await secondFuture;
    expect(secondCompleted, isTrue);
    expect(connectionCount, 1);

    await conn2.close();
    await dataSource.dispose();
    await server.close();
  });

  test('DpgsqlDataSource times out when pool wait exceeds Timeout', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;

    server.listen((client) {
      client.listen((chunk) {
        if (chunk.length > 8 && chunk[0] == 0) {
          final authOk = [0x52, 0, 0, 0, 8, 0, 0, 0, 0];
          final ready = [0x5A, 0, 0, 0, 5, 0x49];
          client.add([...authOk, ...ready]);
        }
      });
    });

    final dataSource = DpgsqlDataSource(
      'Host=localhost; Port=$port; Maximum Pool Size=1; Timeout=0',
    );

    final conn1 = await dataSource.openConnection();

    await expectLater(
      dataSource.openConnection(),
      throwsA(isA<TimeoutException>()),
    );
    expect(dataSource.totalConnectionTimeouts, 1);

    await conn1.close();
    await dataSource.dispose();
    await server.close();
  });

  test('DpgsqlDataSource warmup pre-creates minimum pool size', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;

    var connectionCount = 0;
    server.listen((client) {
      connectionCount++;
      client.listen((chunk) {
        if (chunk.length > 8 && chunk[0] == 0) {
          final authOk = [0x52, 0, 0, 0, 8, 0, 0, 0, 0];
          final ready = [0x5A, 0, 0, 0, 5, 0x49];
          client.add([...authOk, ...ready]);
        }
      });
    });

    final dataSource = DpgsqlDataSource(
      'Host=localhost; Port=$port; Minimum Pool Size=2; Maximum Pool Size=4',
    );

    await dataSource.warmup();
    expect(dataSource.idleCount, 2);
    expect(connectionCount, 2);

    await dataSource.dispose();
    await server.close();
  });

  test('DpgsqlDataSource discards connector returned with active reader',
      () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;

    var connectionCount = 0;
    server.listen((client) {
      connectionCount++;
      client.listen((chunk) {
        if (chunk.length > 8 && chunk[0] == 0) {
          final authOk = [0x52, 0, 0, 0, 8, 0, 0, 0, 0];
          final ready = [0x5A, 0, 0, 0, 5, 0x49];
          client.add([...authOk, ...ready]);
        }

        if (chunk.isNotEmpty && chunk[0] == 81) {
          client.add(_singleIntResultMessages());
        }
      });
    });

    final dataSource = DpgsqlDataSource(
      'Host=localhost; Port=$port; Maximum Pool Size=1',
    );

    final conn1 = await dataSource.openConnection();
    final reader = await conn1.executeReader('SELECT 1');
    expect(await reader.read(), isTrue);

    await conn1.close();
    expect(dataSource.totalCount, 0);

    final conn2 = await dataSource.openConnection();
    expect(connectionCount, 2);

    await conn2.close();
    await dataSource.dispose();
    await server.close();
  });

  test('DpgsqlDataSource discards connector returned with active transaction',
      () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;

    var connectionCount = 0;
    server.listen((client) {
      connectionCount++;
      client.listen((chunk) {
        if (chunk.length > 8 && chunk[0] == 0) {
          final authOk = [0x52, 0, 0, 0, 8, 0, 0, 0, 0];
          final ready = [0x5A, 0, 0, 0, 5, 0x49];
          client.add([...authOk, ...ready]);
        }

        if (chunk.isNotEmpty && chunk[0] == 81) {
          client.add(_commandCompleteMessages('BEGIN'));
        }
      });
    });

    final dataSource = DpgsqlDataSource(
      'Host=localhost; Port=$port; Maximum Pool Size=1',
    );

    final conn1 = await dataSource.openConnection();
    await conn1.beginTransaction();
    await conn1.close();
    expect(dataSource.totalCount, 0);

    final conn2 = await dataSource.openConnection();
    expect(connectionCount, 2);

    await conn2.close();
    await dataSource.dispose();
    await server.close();
  });

  test('DpgsqlDataSource discards connector returned with active COPY',
      () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;

    var connectionCount = 0;
    server.listen((client) {
      connectionCount++;
      client.listen((chunk) {
        if (chunk.length > 8 && chunk[0] == 0) {
          final authOk = [0x52, 0, 0, 0, 8, 0, 0, 0, 0];
          final ready = [0x5A, 0, 0, 0, 5, 0x49];
          client.add([...authOk, ...ready]);
        }

        if (chunk.isNotEmpty && chunk[0] == 81) {
          client.add(_copyInResponseMessage());
        }
      });
    });

    final dataSource = DpgsqlDataSource(
      'Host=localhost; Port=$port; Maximum Pool Size=1',
    );

    final conn1 = await dataSource.openConnection();
    await conn1.beginBinaryImport(
      'COPY pool_copy_test (id) FROM STDIN (FORMAT BINARY)',
    );

    await conn1.close();
    expect(dataSource.totalCount, 0);

    final conn2 = await dataSource.openConnection();
    expect(connectionCount, 2);

    await conn2.close();
    await dataSource.dispose();
    await server.close();
  });

  test('DpgsqlDataSource discards connector after cancelled COPY', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;

    var connectionCount = 0;
    server.listen((client) {
      connectionCount++;
      client.listen((chunk) {
        if (chunk.length > 8 && chunk[0] == 0) {
          final authOk = [0x52, 0, 0, 0, 8, 0, 0, 0, 0];
          final ready = [0x5A, 0, 0, 0, 5, 0x49];
          client.add([...authOk, ...ready]);
        }

        if (chunk.isNotEmpty && chunk[0] == 81) {
          client.add(_copyInResponseMessage());
        }
      });
    });

    final dataSource = DpgsqlDataSource(
      'Host=localhost; Port=$port; Maximum Pool Size=1',
    );

    final conn1 = await dataSource.openConnection();
    final importer = await conn1.beginBinaryImport(
      'COPY pool_copy_test (id) FROM STDIN (FORMAT BINARY)',
    );
    await importer.close();
    await conn1.close();
    expect(dataSource.totalCount, 0);

    final conn2 = await dataSource.openConnection();
    expect(connectionCount, 2);

    await conn2.close();
    await dataSource.dispose();
    await server.close();
  });
}

List<int> _singleIntResultMessages() {
  final rowDesc = <int>[
    0x54,
    0,
    0,
    0,
    0,
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
    0,
  ];
  rowDesc[4] = 29;

  final dataRow = <int>[
    0x44,
    0,
    0,
    0,
    11,
    0,
    1,
    0,
    0,
    0,
    1,
    49,
  ];

  return [
    ...rowDesc,
    ...dataRow,
    ..._commandCompleteMessages('SELECT 1'),
  ];
}

List<int> _commandCompleteMessages(String tag) {
  final tagBytes = tag.codeUnits;
  return [
    0x43,
    0,
    0,
    0,
    tagBytes.length + 5,
    ...tagBytes,
    0,
    0x5A,
    0,
    0,
    0,
    5,
    0x49,
  ];
}

List<int> _copyInResponseMessage() {
  return [
    0x47, // CopyInResponse
    0, 0, 0, 7,
    1, // overall binary format
    0, 0, // zero columns in mock response
  ];
}
