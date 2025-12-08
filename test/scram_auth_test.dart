import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dpgsql/dpgsql.dart';
import 'package:pointycastle/export.dart';
import 'package:test/test.dart';

void main() {
  test('SCRAM-SHA-256 Authentication Success with Server Signature', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;

    final password = 'pencil';
    final salt = base64.decode('QSXCR+Q6sek8bf92');
    final iterations = 4096;
    final serverNoncePart = '3rfcNHYJY1ZVvWVs7j';

    server.listen((client) {
      int state = 0; // 0: Startup, 1: Initial, 2: Final

      client.listen((chunk) {
        if (chunk.isEmpty) return;

        if (state == 0) {
          if (chunk.length > 8) {
            // Send AuthenticationSASL
            final mech = 'SCRAM-SHA-256';
            final mechBytes = utf8.encode(mech);
            final body = [
              0, 0, 0, 10, // AuthSASL code
              ...mechBytes, 0, // Mechanism
              0 // End of mechanisms
            ];
            final msg = [
              0x52, // 'R'
              ..._int32(body.length + 4),
              ...body
            ];
            client.add(msg);
            state = 1;
          }
        } else if (state == 1) {
          // Expect SASLInitialResponse ('p')
          if (chunk[0] == 112) {
            var offset = 5;
            while (offset < chunk.length && chunk[offset] != 0) offset++;
            offset++;
            if (offset + 4 > chunk.length) return;
            final payloadLen = (chunk[offset] << 24) |
                (chunk[offset + 1] << 16) |
                (chunk[offset + 2] << 8) |
                chunk[offset + 3];
            offset += 4;
            if (offset + payloadLen > chunk.length) return;
            final payloadBytes = chunk.sublist(offset, offset + payloadLen);
            final payloadStr = String.fromCharCodes(payloadBytes);

            final rIndex = payloadStr.indexOf('r=');
            if (rIndex == -1) return;
            final commaIndex = payloadStr.indexOf(',', rIndex);
            final clientNonce = payloadStr.substring(
                rIndex + 2, commaIndex == -1 ? null : commaIndex);

            final serverNonce = clientNonce + serverNoncePart;
            final saltB64 = base64.encode(salt);
            final payloadResp = 'r=$serverNonce,s=$saltB64,i=$iterations';

            // Store for calculation
            _serverNonce = serverNonce;
            _clientFirstMessageBare =
                payloadStr.substring(payloadStr.indexOf('n='));

            final payloadRespBytes = utf8.encode(payloadResp);
            final body = [
              0, 0, 0, 11, // AuthSASLContinue code
              ...payloadRespBytes
            ];
            final msg = [
              0x52, // 'R'
              ..._int32(body.length + 4),
              ...body
            ];
            client.add(msg);
            state = 2;
          }
        } else if (state == 2) {
          // Expect SASLResponse ('p')
          if (chunk[0] == 112) {
            // Read client final message
            // Message: 'p' (1) + Len (4) + Payload
            final msgLen = (chunk[1] << 24) |
                (chunk[2] << 16) |
                (chunk[3] << 8) |
                chunk[4];
            final payloadLen = msgLen - 4;

            final payloadBytes = chunk.sublist(5, 5 + payloadLen);
            final clientFinalMessage = String.fromCharCodes(payloadBytes);

            // Calculate Server Signature
            // AuthMessage = client-first-message-bare + "," + server-first-message + "," + client-final-message-without-proof
            final clientFinalMessageWithoutProof = clientFinalMessage.substring(
                0, clientFinalMessage.indexOf(',p='));
            final serverFirstMessage =
                'r=$_serverNonce,s=${base64.encode(salt)},i=$iterations';
            final authMessage =
                '$_clientFirstMessageBare,$serverFirstMessage,$clientFinalMessageWithoutProof';

            final saltedPassword = _hi(password, salt, iterations);
            final serverKey = _hmac(saltedPassword, 'Server Key');
            final serverSignature = _hmac(serverKey, authMessage);
            final v = base64.encode(serverSignature);

            // Send AuthenticationSASLFinal
            final finalBody = utf8.encode('v=$v');
            final finalMsgBody = [
              0, 0, 0, 12, // AuthSASLFinal code
              ...finalBody
            ];
            final finalMsg = [
              0x52, // 'R'
              ..._int32(finalMsgBody.length + 4),
              ...finalMsgBody
            ];
            client.add(finalMsg);

            // Send AuthenticationOk
            final authOk = [
              0x52, // 'R'
              0, 0, 0, 8,
              0, 0, 0, 0 // AuthOk code
            ];
            final ready = [
              0x5A, // 'Z'
              0, 0, 0, 5,
              0x49 // 'I'
            ];
            client.add([...authOk, ...ready]);
            state = 3;
          }
        }
      });
    });

    final conn = NpgsqlConnection(
        'Host=localhost; Port=$port; Username=postgres; Password=$password');

    await conn.open();
    expect(conn.state, ConnectionState.open);
    await conn.close();
    await server.close();
  });
}

String _clientFirstMessageBare = '';
String _serverNonce = '';

List<int> _int32(int value) {
  final bd = ByteData(4)..setInt32(0, value);
  return bd.buffer.asUint8List();
}

Uint8List _hi(String password, Uint8List salt, int iterations) {
  final mac = HMac(SHA256Digest(), 64);
  final pkcs = PBKDF2KeyDerivator(mac)
    ..init(Pbkdf2Parameters(salt, iterations, 32));
  return pkcs.process(utf8.encode(password));
}

Uint8List _hmac(Uint8List key, String data) {
  final hmac = HMac(SHA256Digest(), 64)..init(KeyParameter(key));
  return hmac.process(utf8.encode(data));
}
