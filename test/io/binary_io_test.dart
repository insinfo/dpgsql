import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dpgsql/src/io/binary_input.dart';
import 'package:dpgsql/src/io/binary_output.dart';
import 'package:test/test.dart';

void main() {
  group('MemoryBinaryInput', () {
    test('lê inteiros big-endian corretamente', () async {
      final bytes = Uint8List.fromList([
        0x01, // uint8
        0x00, 0x02, // int16 = 2
        0x00, 0x00, 0x00, 0x03, // int32 = 3
      ]);

      final input = MemoryBinaryInput(bytes);

      await input.ensureBytes(7);
      expect(input.readUint8(), 1);
      expect(input.readInt16(), 2);
      expect(input.readInt32(), 3);
    });

    test('ensureBytes lança EOF quando não há dados suficientes', () async {
      final input = MemoryBinaryInput(Uint8List.fromList([1, 2]));
      await expectLater(
        input.ensureBytes(3),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('MemoryBinaryOutput', () {
    test('escreve valores e retorna buffer esperado', () {
      final output = MemoryBinaryOutput();

      output.writeUint8(1);
      output.writeInt16(2);
      output.writeInt32(3);
      output.writeBytes([4, 5, 6]);

      expect(
        output.toUint8List(),
        orderedEquals([
          0x01,
          0x00,
          0x02,
          0x00,
          0x00,
          0x00,
          0x03,
          0x04,
          0x05,
          0x06,
        ]),
      );
    });
  });

  group('SocketBinaryInput', () {
    test('lê dados chegando em partes e sinaliza EOF', () async {
      await _withSocketPair((client, serverSide) async {
        final input = SocketBinaryInput(client);

        // Envia um byte e um int16 primeiro.
        serverSide.add([0x01, 0x00, 0x02]);
        await serverSide.flush();

        await input.ensureBytes(3);
        expect(input.readUint8(), 1);
        expect(input.readInt16(), 2);

        // Agora envia um int32.
        serverSide.add([0x00, 0x00, 0x00, 0x05]);
        await serverSide.flush();

        await input.ensureBytes(4);
        expect(input.readInt32(), 5);

        // Fecha o lado do servidor para gerar EOF.
        await serverSide.close();
        // Pequeno delay para o evento de "done" propagar.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await expectLater(
          input.ensureBytes(1),
          throwsA(isA<StateError>()),
        );
      });
    });
  });

  group('SocketBinaryOutput', () {
    test('flusha para o socket destino', () async {
      await _withSocketPair((client, serverSide) async {
        final received = BytesBuilder(copy: false);
        final done = Completer<void>();

        serverSide.listen(
          received.add,
          onDone: () => done.complete(),
        );

        final output = SocketBinaryOutput(client);
        output.writeUint8(1);
        output.writeInt16(2);
        output.writeInt32(3);
        output.writeBytes([4, 5, 6]);
        await output.flush();

        await client.close();
        await done.future;

        expect(
          received.takeBytes(),
          orderedEquals([
            0x01,
            0x00,
            0x02,
            0x00,
            0x00,
            0x00,
            0x03,
            0x04,
            0x05,
            0x06,
          ]),
        );
      });
    });
  });
}

Future<void> _withSocketPair(
  Future<void> Function(Socket client, Socket serverSide) body,
) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final client = await Socket.connect(InternetAddress.loopbackIPv4, server.port);
  final serverSide = await server.first;

  try {
    await body(client, serverSide);
  } finally {
    await client.close().catchError((_) {});
    await serverSide.close().catchError((_) {});
    await server.close();
  }
}
