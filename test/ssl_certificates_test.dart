// Root Certificate, SSL Certificate, SSL Key, SSL Password and
// DpgsqlConnectionStringBuilder.securityContext: a private CA verifies the
// server, the client certificate reaches it, and settings that cannot be
// honored fail before anything is sent.
//
// A fake server on loopback answers 'S' to the SSLRequest and accepts TLS with
// the certificates in test/fixtures/tls (made for these tests only, see
// generate.sh). The startup message reaching it means the client accepted the
// server: it carries the user name.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dpgsql/dpgsql.dart';
import 'package:test/test.dart';

const _dir = 'test/fixtures/tls';

bool _isSslRequest(List<int> chunk) {
  if (chunk.length < 8) return false;
  final data = ByteData.sublistView(Uint8List.fromList(chunk));
  return data.getInt32(0) == 8 && data.getInt32(4) == 80877103;
}

class _FakeServer {
  _FakeServer._(this._socket, this._context, this._requireClient) {
    _socket.listen(_serve);
  }

  static Future<_FakeServer> start(
      {String certificate = 'server', bool requireClient = false}) async {
    final context = SecurityContext()
      ..useCertificateChain('$_dir/$certificate.pem')
      ..usePrivateKey('$_dir/$certificate-key.pem');
    if (requireClient) {
      context
        ..setTrustedCertificates('$_dir/ca.pem')
        ..setClientAuthorities('$_dir/ca.pem');
    }
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    return _FakeServer._(server, context, requireClient);
  }

  final ServerSocket _socket;
  final SecurityContext _context;
  final bool _requireClient;

  bool startupReceived = false;
  String? clientSubject;

  int get port => _socket.port;

  void _serve(Socket client) {
    late StreamSubscription<Uint8List> sub;
    sub = client.listen((chunk) async {
      if (!_isSslRequest(chunk)) return;
      sub.pause();
      client.add([83]); // 'S'
      await client.flush();
      try {
        final secure = await SecureSocket.secureServer(client, _context,
            requireClientCertificate: _requireClient);
        clientSubject = secure.peerCertificate?.subject;
        await secure.first;
        startupReceived = true;
        secure.destroy();
      } catch (_) {
        // The handshake failed: the client rejected the certificate, or the
        // server rejected the client.
      }
    }, onError: (_) {});
  }

  Future<void> close() => _socket.close();
}

Future<Object?> _open(DpgsqlConnectionStringBuilder builder) async {
  final connection = DpgsqlConnection.fromConnectionStringBuilder(builder);
  try {
    await connection.open().timeout(const Duration(seconds: 10));
    return null;
  } catch (e) {
    return e;
  } finally {
    await connection.close();
  }
}

Future<Object?> _openString(String connectionString) async {
  final connection = DpgsqlConnection(connectionString);
  try {
    await connection.open().timeout(const Duration(seconds: 10));
    return null;
  } catch (e) {
    return e;
  } finally {
    await connection.close();
  }
}

/// Lets the fake server see what the client sent before the assertions.
Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 50));

void main() {
  group('Root Certificate', () {
    test('verifies a server with a certificate of that CA', () async {
      final server = await _FakeServer.start();
      addTearDown(server.close);
      await _openString('Host=localhost; Port=${server.port}; '
          'SSL Mode=VerifyFull; Root Certificate=$_dir/ca.pem');
      await _settle();
      expect(server.startupReceived, isTrue);
    });

    test('without it the system roots reject the private CA', () async {
      final server = await _FakeServer.start();
      addTearDown(server.close);
      final error = await _openString(
          'Host=localhost; Port=${server.port}; SSL Mode=VerifyFull');
      await _settle();
      expect('$error', contains('CERTIFICATE_VERIFY_FAILED'));
      expect(server.startupReceived, isFalse);
    });

    test('another CA rejects the certificate', () async {
      final server = await _FakeServer.start();
      addTearDown(server.close);
      final error = await _openString('Host=localhost; Port=${server.port}; '
          'SSL Mode=VerifyFull; Root Certificate=$_dir/other-ca.pem');
      await _settle();
      expect('$error', contains('CERTIFICATE_VERIFY_FAILED'));
      expect(server.startupReceived, isFalse);
    });

    test('a certificate for another host is rejected', () async {
      final server = await _FakeServer.start(certificate: 'server-other-host');
      addTearDown(server.close);
      final error = await _openString('Host=localhost; Port=${server.port}; '
          'SSL Mode=VerifyFull; Root Certificate=$_dir/ca.pem');
      await _settle();
      expect(error, isNotNull);
      expect(server.startupReceived, isFalse);
    });

    test('a data source uses it for its connections', () async {
      final server = await _FakeServer.start();
      addTearDown(server.close);
      final dataSource = DpgsqlDataSource('Host=localhost; Port=${server.port}; '
          'SSL Mode=VerifyFull; Root Certificate=$_dir/ca.pem; Timeout=5');
      addTearDown(dataSource.dispose);
      await expectLater(dataSource.openConnection(), throwsA(anything));
      await _settle();
      expect(server.startupReceived, isTrue);
    });
  });

  group('client certificate', () {
    test('reaches a server that requires one', () async {
      final server = await _FakeServer.start(requireClient: true);
      addTearDown(server.close);
      await _openString('Host=localhost; Port=${server.port}; '
          'SSL Mode=VerifyFull; Root Certificate=$_dir/ca.pem; '
          'SSL Certificate=$_dir/client.pem; SSL Key=$_dir/client-key.pem');
      await _settle();
      expect(server.startupReceived, isTrue);
      expect(server.clientSubject, contains('eloquent-client'));
    });

    test('works with SSL Mode=Require, which does not verify the server',
        () async {
      final server = await _FakeServer.start(requireClient: true);
      addTearDown(server.close);
      await _openString('Host=localhost; Port=${server.port}; SSL Mode=Require; '
          'SSL Certificate=$_dir/client.pem; SSL Key=$_dir/client-key.pem');
      await _settle();
      expect(server.clientSubject, contains('eloquent-client'));
    });

    test('an encrypted key is read with SSL Password', () async {
      final server = await _FakeServer.start(requireClient: true);
      addTearDown(server.close);
      await _openString('Host=localhost; Port=${server.port}; SSL Mode=Require; '
          'SSL Certificate=$_dir/client.pem; '
          'SSL Key=$_dir/client-key-encrypted.pem; SSL Password=secret');
      await _settle();
      expect(server.clientSubject, contains('eloquent-client'));
    });

    test('a server that requires one refuses a client without it', () async {
      final server = await _FakeServer.start(requireClient: true);
      addTearDown(server.close);
      await _openString('Host=localhost; Port=${server.port}; '
          'SSL Mode=VerifyFull; Root Certificate=$_dir/ca.pem');
      await _settle();
      expect(server.startupReceived, isFalse);
    });
  });

  group('securityContext', () {
    test('verifies the server with certificates from memory', () async {
      final server = await _FakeServer.start();
      addTearDown(server.close);
      final builder =
          DpgsqlConnectionStringBuilder('Host=localhost; Port=${server.port}; '
              'SSL Mode=VerifyFull')
            ..securityContext = (SecurityContext()
              ..setTrustedCertificatesBytes(
                  File('$_dir/ca.pem').readAsBytesSync()));
      await _open(builder);
      await _settle();
      expect(server.startupReceived, isTrue);
    });

    test('a data source built from the builder uses it', () async {
      final server = await _FakeServer.start();
      addTearDown(server.close);
      final builder = DpgsqlConnectionStringBuilder(
          'Host=localhost; Port=${server.port}; SSL Mode=VerifyFull; Timeout=5')
        ..securityContext = (SecurityContext()
          ..setTrustedCertificates('$_dir/ca.pem'));
      final dataSource = DpgsqlDataSource.fromConnectionStringBuilder(builder);
      addTearDown(dataSource.dispose);
      await expectLater(dataSource.openConnection(), throwsA(anything));
      await _settle();
      expect(server.startupReceived, isTrue);
    });
  });

  group('settings that cannot be honored throw ArgumentError', () {
    final cases = {
      'Root Certificate with Require':
          'SSL Mode=Require; Root Certificate=$_dir/ca.pem',
      'Root Certificate with Prefer':
          'SSL Mode=Prefer; Root Certificate=$_dir/ca.pem',
      'certificates with Disable':
          'SSL Mode=Disable; SSL Certificate=$_dir/client.pem; '
              'SSL Key=$_dir/client-key.pem',
      'SSL Certificate without SSL Key':
          'SSL Mode=Require; SSL Certificate=$_dir/client.pem',
      'SSL Key without SSL Certificate':
          'SSL Mode=Require; SSL Key=$_dir/client-key.pem',
      'a Root Certificate that does not exist':
          'SSL Mode=VerifyFull; Root Certificate=$_dir/missing.pem',
      'a Root Certificate that is not a certificate':
          'SSL Mode=VerifyFull; Root Certificate=$_dir/generate.sh',
      'an encrypted key with the wrong password':
          'SSL Mode=Require; SSL Certificate=$_dir/client.pem; '
              'SSL Key=$_dir/client-key-encrypted.pem; SSL Password=wrong',
    };
    cases.forEach((name, settings) {
      test(name, () {
        expect(
            () => DpgsqlConnectionStringBuilder('Host=localhost; $settings')
                .resolveSecurityContext(),
            throwsArgumentError);
      });
    });

    test('securityContext with Root Certificate', () {
      final builder = DpgsqlConnectionStringBuilder(
          'Host=localhost; SSL Mode=VerifyFull; Root Certificate=$_dir/ca.pem')
        ..securityContext = SecurityContext();
      expect(builder.resolveSecurityContext, throwsArgumentError);
    });

    test('securityContext with Disable', () {
      final builder = DpgsqlConnectionStringBuilder(
          'Host=localhost; SSL Mode=Disable')
        ..securityContext = SecurityContext();
      expect(builder.resolveSecurityContext, throwsArgumentError);
    });

    test('open() reports it and leaves the connection closed', () async {
      final connection = DpgsqlConnection(
          'Host=localhost; SSL Mode=Require; Root Certificate=$_dir/ca.pem');
      await expectLater(connection.open(), throwsArgumentError);
      expect(connection.state, ConnectionState.closed);
    });
  });

  test('no certificates: no context, the system roots verify', () {
    final builder =
        DpgsqlConnectionStringBuilder('Host=localhost; SSL Mode=VerifyFull');
    expect(builder.resolveSecurityContext(), isNull);
  });
}
