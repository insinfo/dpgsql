// open() must end on a server that stops answering, and the password goes in
// clear text only to a verified server or by explicit choice.
//
// Fake servers on loopback, no database needed. The TLS ones use the
// certificates in test/fixtures/tls.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dpgsql/dpgsql.dart';
import 'package:test/test.dart';

const _dir = 'test/fixtures/tls';
const _password = 'secret-password';

bool _isSslRequest(List<int> chunk) =>
    chunk.length >= 8 &&
    ByteData.sublistView(Uint8List.fromList(chunk)).getInt32(4) == 80877103;

List<int> _message(String type, List<int> body) {
  final length = ByteData(4)..setInt32(0, body.length + 4);
  return [type.codeUnitAt(0), ...length.buffer.asUint8List(), ...body];
}

final _askCleartext = _message('R', [0, 0, 0, 3]);
final _refused = _message('E', [
  ...latin1.encode('SFATAL\x00VFATAL\x00C28P01\x00Mrefused by fake server\x00'),
  0,
]);

/// [onMessage] gets what the client sends after the SSL negotiation. With
/// [stallTls] the server answers 'S' and never starts the TLS handshake.
Future<ServerSocket> _server({
  bool tls = false,
  bool stallTls = false,
  void Function(List<int> chunk, void Function(List<int>) send)? onMessage,
}) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((client) {
    // ignore: cancel_subscriptions
    late StreamSubscription<Uint8List> sub;
    sub = client.listen((chunk) async {
      if (!_isSslRequest(chunk)) {
        onMessage?.call(chunk, client.add);
        return;
      }
      if (stallTls) {
        client.add([0x53]);
        return;
      }
      if (!tls) {
        client.add([0x4E]);
        return;
      }
      sub.pause();
      client.add([0x53]);
      await client.flush();
      try {
        final secure = await SecureSocket.secureServer(
            client,
            SecurityContext()
              ..useCertificateChain('$_dir/server.pem')
              ..usePrivateKey('$_dir/server-key.pem'));
        secure.listen((data) => onMessage?.call(data, secure.add),
            onError: (_) {});
      } catch (_) {
        // The client rejected the certificate.
      }
    }, onError: (_) {});
  });
  return server;
}

Future<Object?> _open(String settings) async {
  final connection = DpgsqlConnection(settings);
  try {
    await connection.open().timeout(const Duration(seconds: 8));
    return null;
  } catch (e) {
    return e;
  } finally {
    await connection.close();
  }
}

/// A server that asks for the password in clear text and records if it came.
class _PasswordTrap {
  bool received = false;
  void call(List<int> chunk, void Function(List<int>) send) {
    if (utf8.decode(chunk, allowMalformed: true).contains(_password)) {
      received = true;
      send(_refused);
    } else {
      send(_askCleartext);
    }
  }
}

String _base(int port) => 'Host=localhost;Port=$port;Database=db;'
    'Username=user;Password=$_password;Timeout=1;';

void main() {
  group('Timeout bounds open()', () {
    test('a server that never answers the startup', () async {
      final server = await _server();
      addTearDown(server.close);
      final error = await _open('${_base(server.port)}SSL Mode=Disable');
      expect(error, isA<TimeoutException>());
    });

    test('a server that stalls the TLS handshake', () async {
      final server = await _server(stallTls: true);
      addTearDown(server.close);
      final error = await _open('${_base(server.port)}SSL Mode=Require');
      expect(error, isA<TimeoutException>());
    });

    test('a TLS server that never answers the startup', () async {
      final server = await _server(tls: true);
      addTearDown(server.close);
      final error = await _open('${_base(server.port)}SSL Mode=Require');
      expect(error, isA<TimeoutException>());
    });

    test('the connection can be opened again after it', () async {
      final server = await _server();
      addTearDown(server.close);
      final connection =
          DpgsqlConnection('${_base(server.port)}SSL Mode=Disable');
      await expectLater(connection.open(), throwsA(isA<TimeoutException>()));
      expect(connection.state, ConnectionState.closed);
      await expectLater(connection.open(), throwsA(isA<TimeoutException>()));
      await connection.close();
    });

    test('a data source reports it', () async {
      final server = await _server();
      addTearDown(server.close);
      final dataSource =
          DpgsqlDataSource('${_base(server.port)}SSL Mode=Disable');
      addTearDown(dataSource.dispose);
      await expectLater(
          dataSource.openConnection().timeout(const Duration(seconds: 8)),
          throwsA(isA<TimeoutException>()));
    });

    test('zero means no limit', () async {
      final server = await _server();
      addTearDown(server.close);
      final connection = DpgsqlConnection('Host=localhost;Port=${server.port};'
          'Database=db;Username=user;Password=$_password;Timeout=0;'
          'SSL Mode=Disable');
      var ended = false;
      unawaited(connection
          .open()
          .whenComplete(() => ended = true)
          .catchError((_) {}));
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(ended, isFalse);
      await connection.close();
    });
  });

  group('password in clear text', () {
    for (final mode in ['Disable', 'Prefer', 'Require']) {
      test('not sent with SSL Mode=$mode', () async {
        final trap = _PasswordTrap();
        final server =
            await _server(tls: mode == 'Require', onMessage: trap.call);
        addTearDown(server.close);
        final error = await _open('${_base(server.port)}SSL Mode=$mode');
        expect('$error', contains('clear text'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(trap.received, isFalse);
      });
    }

    test('sent with Allow Cleartext Password=true', () async {
      final trap = _PasswordTrap();
      final server = await _server(onMessage: trap.call);
      addTearDown(server.close);
      await _open('${_base(server.port)}SSL Mode=Disable;'
          'Allow Cleartext Password=true');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(trap.received, isTrue);
    });

    test('sent to a verified server', () async {
      final trap = _PasswordTrap();
      final server = await _server(tls: true, onMessage: trap.call);
      addTearDown(server.close);
      await _open('${_base(server.port)}SSL Mode=VerifyFull;'
          'Root Certificate=$_dir/ca.pem');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(trap.received, isTrue);
    });

    test('the builder reads and writes the setting', () {
      final builder = DpgsqlConnectionStringBuilder();
      expect(builder.allowCleartextPassword, isFalse);
      builder.allowCleartextPassword = true;
      expect(
          DpgsqlConnectionStringBuilder(builder.toString())
              .allowCleartextPassword,
          isTrue);
    });
  });
}
