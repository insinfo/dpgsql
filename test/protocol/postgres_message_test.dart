

import 'package:dpgsql/src/io/binary_input.dart';
import 'package:dpgsql/src/io/binary_output.dart';
import 'package:dpgsql/src/protocol/postgres_message.dart';
import 'package:test/test.dart';

void main() {
  test('lê mensagem tipo+len+payload', () async {
    final out = MemoryBinaryOutput();
    // Mensagem: tipo 'R' (0x52), length=8 (4 bytes de body), body=0xAA 0xBB 0xCC 0xDD
    out.writeUint8('R'.codeUnitAt(0));
    out.writeInt32(8);
    out.writeBytes([0xAA, 0xBB, 0xCC, 0xDD]);

    final input = MemoryBinaryInput(out.toUint8List());
    final reader = PostgresMessageReader(input);

    final msg = await reader.readMessage();
    expect(msg.typeCode, 'R'.codeUnitAt(0));
    expect(msg.length, 8);
    expect(msg.payload, orderedEquals([0xAA, 0xBB, 0xCC, 0xDD]));
  });

  test('escreve mensagem com length correto', () async {
    final sink = MemoryBinaryOutput();
    final writer = PostgresMessageWriter(sink);

    await writer.writeMessage('Q'.codeUnitAt(0), (body) {
      body.writeBytes([0x10, 0x20]);
    });

    final bytes = sink.toUint8List();
    final input = MemoryBinaryInput(bytes);
    final reader = PostgresMessageReader(input);
    final msg = await reader.readMessage();

    expect(msg.typeCode, 'Q'.codeUnitAt(0));
    expect(msg.length, 6); // 2 bytes de payload + 4 do length
    expect(msg.payload, orderedEquals([0x10, 0x20]));
  });
}
