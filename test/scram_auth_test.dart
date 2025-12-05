import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dpgsql/dpgsql.dart';
import 'package:test/test.dart';

void main() {
  test('SCRAM-SHA-256 Authentication Success', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;

    final password = 'pencil';
    final salt = base64.decode('QSXCR+Q6sek8bf92');
    final iterations = 4096;
    final serverNoncePart = '3rfcNHYJY1ZVvWVs7j';

    server.listen((client) {
      int state =
          0; // 0: Expect Startup, 1: Expect InitialResponse, 2: Expect FinalResponse

      client.listen((chunk) {
        if (chunk.isEmpty) return;

        if (state == 0) {
          // Expect Startup
          // Startup message starts with length (int32), not a type code.
          // But usually the first byte is part of the length, so it's not 0 unless length is huge.
          // Actually, Startup message format: Length(Int32), Protocol(Int32), ...
          // So chunk[0] is part of length.

          // We just check if it looks like a startup (len > 8)
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
            // 'p'
            // Parse binary
            var offset = 5; // Skip 'p' (1) + MsgLen (4)

            // Read Mechanism (CString)
            while (offset < chunk.length && chunk[offset] != 0) offset++;
            // final mech = String.fromCharCodes(chunk.sublist(mechStart, offset));
            offset++; // Skip \0

            // Read Payload Length (Int32)
            if (offset + 4 > chunk.length) return; // Incomplete

            final payloadLen = (chunk[offset] << 24) |
                (chunk[offset + 1] << 16) |
                (chunk[offset + 2] << 8) |
                chunk[offset + 3];
            offset += 4;

            // Read Payload
            if (offset + payloadLen > chunk.length) return; // Incomplete

            final payloadBytes = chunk.sublist(offset, offset + payloadLen);
            final payloadStr = String.fromCharCodes(payloadBytes);

            // Payload: n,,n=user,r=clientNonce
            final rIndex = payloadStr.indexOf('r=');
            if (rIndex == -1) {
              // Fail
              return;
            }

            final commaIndex = payloadStr.indexOf(',', rIndex);
            final clientNonce = payloadStr.substring(
                rIndex + 2, commaIndex == -1 ? null : commaIndex);

            final serverNonce = clientNonce + serverNoncePart;

            // Send AuthenticationSASLContinue
            // Payload: r=serverNonce,s=base64(salt),i=iterations
            final saltB64 = base64.encode(salt);
            final payloadResp = 'r=$serverNonce,s=$saltB64,i=$iterations';
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
            // 'p'
            // Send AuthenticationOk
            final authOk = [
              0x52, // 'R'
              0, 0, 0, 8,
              0, 0, 0, 0 // AuthOk code
            ];

            // Send ReadyForQuery
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

List<int> _int32(int value) {
  final bd = ByteData(4)..setInt32(0, value);
  return bd.buffer.asUint8List();
}
