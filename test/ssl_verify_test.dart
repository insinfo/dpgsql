// SSL Mode=VerifyCA/VerifyFull must never end in a connection the server
// was not verified for: not in plain text when the server refuses SSL, and
// not with an untrusted certificate (Trust Server Certificate, true by
// default in the connection string, does not apply to them). Require keeps
// encrypting without verifying.
//
// Fake servers on loopback: one answers 'N' to the SSLRequest, the other
// accepts TLS with the self-signed certificate in test/fixtures/tls
// (CN=localhost, made for these tests only).
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dpgsql/dpgsql.dart';
import 'package:test/test.dart';

bool _isSslRequest(List<int> chunk) {
  if (chunk.length < 8) return false;
  final data = ByteData.sublistView(Uint8List.fromList(chunk));
  return data.getInt32(0) == 8 && data.getInt32(4) == 80877103;
}

/// Answers 'N' to the SSLRequest, then closes.
Future<ServerSocket> _refusingServer() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((client) {
    client.listen((chunk) {
      if (_isSslRequest(chunk)) {
        client.add([78]); // 'N'
      } else {
        client.destroy();
      }
    }, onError: (_) {});
  });
  return server;
}

/// Answers 'S' and completes [handshakes] once a TLS handshake with the
/// test certificate succeeds, then closes the connection.
Future<ServerSocket> _tlsServer(StreamController<void> handshakes) async {
  final context = SecurityContext()
    ..useCertificateChain('test/fixtures/tls/server.crt')
    ..usePrivateKey('test/fixtures/tls/server.key');
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((client) {
    late StreamSubscription<Uint8List> sub;
    sub = client.listen((chunk) async {
      if (!_isSslRequest(chunk)) return;
      sub.pause();
      client.add([83]); // 'S'
      await client.flush();
      try {
        final secure = await SecureSocket.secureServer(client, context);
        handshakes.add(null);
        secure.destroy();
      } catch (_) {
        // The client rejected the certificate.
      }
    }, onError: (_) {});
  });
  return server;
}

Future<Object?> _openError(String connectionString) async {
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

void main() {
  group('a server that refuses SSL', () {
    for (final mode in ['VerifyCA', 'VerifyFull', 'Require']) {
      test('SSL Mode=$mode fails instead of connecting in plain text',
          () async {
        final server = await _refusingServer();
        addTearDown(server.close);
        final error = await _openError(
            'Host=localhost; Port=${server.port}; SSL Mode=$mode');
        expect(error, isA<PostgresException>(), reason: '$error');
        expect((error as PostgresException).messageText,
            contains('does not support SSL'));
      });
    }
  });

  group('an untrusted certificate', () {
    late StreamController<void> handshakes;
    late ServerSocket server;
    var completed = 0;

    setUp(() async {
      completed = 0;
      handshakes = StreamController<void>.broadcast()
        ..stream.listen((_) => completed++);
      server = await _tlsServer(handshakes);
    });

    tearDown(() async {
      await server.close();
      await handshakes.close();
    });

    for (final extra in ['', '; Trust Server Certificate=true']) {
      for (final mode in ['VerifyCA', 'VerifyFull']) {
        test('SSL Mode=$mode$extra rejects it', () async {
          final error = await _openError(
              'Host=localhost; Port=${server.port}; SSL Mode=$mode$extra');
          expect(error, isNotNull);
          expect('$error', contains('CERTIFICATE_VERIFY_FAILED'),
              reason: '$error');
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(completed, 0, reason: 'no TLS session with that server');
        });
      }
    }

    test('SSL Mode=Require encrypts without verifying it', () async {
      await _openError('Host=localhost; Port=${server.port}; SSL Mode=Require');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(completed, 1, reason: 'the TLS handshake completed');
    });
  });
}
