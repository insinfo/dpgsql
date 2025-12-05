import 'dart:typed_data';

import 'package:dpgsql/src/io/binary_input.dart';
import 'package:dpgsql/src/io/binary_output.dart';
import 'package:dpgsql/src/protocol/frontend_messages.dart';
import 'package:dpgsql/src/protocol/postgres_message.dart';
import 'package:test/test.dart';

void main() {
  group('SSLRequest/Startup', () {
    test('SSLRequest gera length=8 e magic code', () async {
      final out = MemoryBinaryOutput();
      final writer = PostgresMessageWriter(out);
      final frontend = FrontendMessages(writer);

      await frontend.writeSslRequest();

      final bytes = out.toUint8List();
      expect(bytes.length, 8);

      final input = MemoryBinaryInput(bytes);
      final length = input.readInt32();
      final code = input.readInt32();
      expect(length, 8);
      expect(code, PostgresProtocol.sslRequestCode);
    });

    test('StartupMessage com user/db/parâmetros', () async {
      final out = MemoryBinaryOutput();
      final writer = PostgresMessageWriter(out);
      final frontend = FrontendMessages(writer);

      await frontend.writeStartupMessage(
        user: 'alice',
        database: 'testdb',
        parameters: {'application_name': 'npgsql_dart'},
      );

      final bytes = out.toUint8List();
      final input = MemoryBinaryInput(bytes);
      final length = input.readInt32();
      final protocol = input.readInt32();
      expect(protocol, PostgresProtocol.protocolVersion);

      // O restante é uma sequência de c-strings terminada por um byte zero.
      final bodyBytes = Uint8List.sublistView(bytes, 8);
      // Deve terminar com \0\0 (terminador extra após o último par chave/valor)
      expect(bodyBytes.last, 0);

      // Valida comprimento geral.
      expect(length, bytes.length);
    });
  });

  group('Query', () {
    test('mensagem Q com sql terminado em \\0', () async {
      final out = MemoryBinaryOutput();
      final writer = PostgresMessageWriter(out);
      final frontend = FrontendMessages(writer);

      await frontend.writeQuery('select 1');

      final input = MemoryBinaryInput(out.toUint8List());
      final reader = PostgresMessageReader(input);
      final msg = await reader.readMessage();

      expect(msg.typeCode, 'Q'.codeUnitAt(0));
      expect(msg.payload.last, 0); // terminador nulo
      expect(String.fromCharCodes(msg.payload.take(msg.payload.length - 1)),
          'select 1');
    });
  });

  group('Parse/Bind/Describe/Execute/Sync/Terminate', () {
    test('Parse com parameter OIDs', () async {
      final out = MemoryBinaryOutput();
      final writer = PostgresMessageWriter(out);
      final frontend = FrontendMessages(writer);

      await frontend.writeParse(
        statementName: 's1',
        query: r'select $1, $2',
        parameterTypeOids: [23, 25],
      );

      final msg = await _readSingleFromOutput(out);
      expect(msg.typeCode, 'P'.codeUnitAt(0));
      final body = msg.payload;
      final input = MemoryBinaryInput(body);

      // statement name
      expect(_readCString(input), 's1');
      // query
      expect(_readCString(input), 'select \$1, \$2');
      // param count
      expect(input.readInt16(), 2);
      expect(input.readInt32(), 23);
      expect(input.readInt32(), 25);
    });

    test('Bind com formatos, valores e formatos de resultado', () async {
      final out = MemoryBinaryOutput();
      final writer = PostgresMessageWriter(out);
      final frontend = FrontendMessages(writer);

      await frontend.writeBind(
        portalName: '',
        statementName: 's1',
        parameterFormatCodes: const [1],
        parameterValues: [
          [0x01, 0x02],
        ],
        resultFormatCodes: const [1],
      );

      final msg = await _readSingleFromOutput(out);
      expect(msg.typeCode, 'B'.codeUnitAt(0));
      final input = MemoryBinaryInput(msg.payload);

      expect(_readCString(input), ''); // portal
      expect(_readCString(input), 's1'); // statement
      expect(input.readInt16(), 1); // format count
      expect(input.readInt16(), 1); // format code
      expect(input.readInt16(), 1); // param value count
      expect(input.readInt32(), 2); // param length
      expect(input.readBytes(2), orderedEquals([0x01, 0x02]));
      expect(input.readInt16(), 1); // result format count
      expect(input.readInt16(), 1); // result format
    });

    test('Describe statement e portal', () async {
      final out1 = MemoryBinaryOutput();
      final writer1 = PostgresMessageWriter(out1);
      final frontend1 = FrontendMessages(writer1);
      await frontend1.writeDescribeStatement('s1');
      final msg1 = await _readSingleFromOutput(out1);
      final input1 = MemoryBinaryInput(msg1.payload);
      expect(msg1.typeCode, 'D'.codeUnitAt(0));
      expect(input1.readUint8(), 'S'.codeUnitAt(0));
      expect(_readCString(input1), 's1');

      final out2 = MemoryBinaryOutput();
      final writer2 = PostgresMessageWriter(out2);
      final frontend2 = FrontendMessages(writer2);
      await frontend2.writeDescribePortal('p1');
      final msg2 = await _readSingleFromOutput(out2);
      final input2 = MemoryBinaryInput(msg2.payload);
      expect(msg2.typeCode, 'D'.codeUnitAt(0));
      expect(input2.readUint8(), 'P'.codeUnitAt(0));
      expect(_readCString(input2), 'p1');
    });

    test('Execute, Sync, Terminate', () async {
      final execOut = MemoryBinaryOutput();
      final execWriter = PostgresMessageWriter(execOut);
      final execFrontend = FrontendMessages(execWriter);
      await execFrontend.writeExecute(portalName: 'p1', maxRows: 10);
      final exec = await _readSingleFromOutput(execOut);
      final execIn = MemoryBinaryInput(exec.payload);
      expect(exec.typeCode, 'E'.codeUnitAt(0));
      expect(_readCString(execIn), 'p1');
      expect(execIn.readInt32(), 10);

      final syncOut = MemoryBinaryOutput();
      final syncWriter = PostgresMessageWriter(syncOut);
      final syncFrontend = FrontendMessages(syncWriter);
      await syncFrontend.writeSync();
      final sync = await _readSingleFromOutput(syncOut);
      expect(sync.typeCode, 'S'.codeUnitAt(0));
      expect(sync.payload.length, 0);

      final termOut = MemoryBinaryOutput();
      final termWriter = PostgresMessageWriter(termOut);
      final termFrontend = FrontendMessages(termWriter);
      await termFrontend.writeTerminate();
      final term = await _readSingleFromOutput(termOut);
      expect(term.typeCode, 'X'.codeUnitAt(0));
      expect(term.payload.length, 0);
    });
  });
}

Future<PostgresMessage> _readSingleFromOutput(MemoryBinaryOutput out) async {
  final reader = PostgresMessageReader(MemoryBinaryInput(out.toUint8List()));
  return reader.readMessage();
}

String _readCString(MemoryBinaryInput input) {
  final bytes = <int>[];
  while (true) {
    final b = input.readUint8();
    if (b == 0) break;
    bytes.add(b);
  }
  return String.fromCharCodes(bytes);
}
