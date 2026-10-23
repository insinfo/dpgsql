// The session settings (search_path, application_name, timeouts) on a
// server whose replies take 150 ms, as one in another region or a busy one:
// they used to run with a fixed 100 ms timeout, so DpgsqlConnection.open()
// failed with a TimeoutException and DpgsqlDataSource handed out
// connections without them.
import 'dart:async';
import 'dart:io';

import 'package:dpgsql/dpgsql.dart';
import 'package:test/test.dart';

import 'test_config.dart';

/// A TCP proxy to [target] that delays every reply of the server by
/// [delay], keeping their order.
class _SlowProxy {
  _SlowProxy._(this._server);

  final ServerSocket _server;
  final _sockets = <Socket>[];

  int get port => _server.port;

  static Future<_SlowProxy> start(String host, int port, Duration delay) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = _SlowProxy._(server);
    server.listen((client) async {
      final upstream = await Socket.connect(host, port);
      proxy._sockets.addAll([client, upstream]);
      client.listen(upstream.add,
          onDone: upstream.destroy, onError: (_) => upstream.destroy());
      var last = Future<void>.value();
      upstream.listen((data) {
        last = last.then((_) async {
          await Future<void>.delayed(delay);
          client.add(data);
        });
      },
          onDone: () => last.then((_) => client.destroy()),
          onError: (_) => client.destroy());
    });
    return proxy;
  }

  Future<void> close() async {
    await _server.close();
    for (final socket in _sockets) {
      socket.destroy();
    }
  }
}

void main() {
  late _SlowProxy proxy;
  late DpgsqlConnectionStringBuilder settings;
  var available = true;

  setUpAll(() async {
    final probe = await openRealConnectionOrSkip();
    if (probe == null) {
      available = false;
      return;
    }
    await probe.close();
    final real = DpgsqlConnectionStringBuilder(realConnectionString());
    proxy = await _SlowProxy.start(
        real.host, real.port, const Duration(milliseconds: 150));
    settings = DpgsqlConnectionStringBuilder(realConnectionString())
      ..host = '127.0.0.1'
      ..port = proxy.port
      ..searchPath = 'pg_catalog, public'
      ..applicationName = 'dpgsql-slow-network'
      ..statementTimeout = '7s';
  });

  tearDownAll(() async {
    if (available) await proxy.close();
  });

  Future<void> expectSettings(DpgsqlConnection connection) async {
    expect(await connection.executeScalar('SHOW search_path'),
        'pg_catalog, public');
    expect(
        await connection
            .executeScalar("SELECT current_setting('application_name')"),
        'dpgsql-slow-network');
    expect(await connection.executeScalar('SHOW statement_timeout'), '7s');
  }

  test('DpgsqlConnection.open applies the settings', () async {
    if (!available) return;
    final connection = DpgsqlConnection.fromConnectionStringBuilder(settings);
    try {
      await connection.open();
      await expectSettings(connection);
    } finally {
      await connection.close();
    }
  }, timeout: const Timeout(Duration(seconds: 60)));

  for (final pooling in [true, false]) {
    test('DpgsqlDataSource (pooling: $pooling) applies the settings', () async {
      if (!available) return;
      final source = DpgsqlDataSource.fromConnectionStringBuilder(
          DpgsqlConnectionStringBuilder(settings.toString())
            ..pooling = pooling);
      try {
        for (var i = 0; i < 2; i++) {
          // The second checkout reuses the pooled connection (reset path).
          final connection = await source.openConnection();
          try {
            await expectSettings(connection);
          } finally {
            await connection.close();
          }
        }
      } finally {
        await source.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 60)));
  }
}
