import 'dart:typed_data';

import 'package:dpgsql/src/io/binary_input.dart';
import 'package:dpgsql/src/protocol/backend_messages.dart';
import 'package:dpgsql/src/protocol/postgres_message.dart';
import 'package:test/test.dart';

void main() {
  group('BackendMessageReader', () {
    test('ReadyForQuery', () async {
      final bytes = _frame(
        BackendMessageCode.readyForQuery.typeCode,
        [TransactionStatus.idle.indicator],
      );

      final reader =
          BackendMessageReader(PostgresMessageReader(MemoryBinaryInput(bytes)));
      final msg = await reader.readMessage() as ReadyForQueryMessage;

      expect(msg.code, BackendMessageCode.readyForQuery);
      expect(msg.transactionStatusIndicator, TransactionStatus.idle);
    });

    test('ParameterStatus', () async {
      final payload = [
        ..._cstring('client_encoding'),
        ..._cstring('UTF8'),
      ];
      final bytes =
          _frame(BackendMessageCode.parameterStatus.typeCode, payload);

      final msg = await BackendMessageReader(
              PostgresMessageReader(MemoryBinaryInput(bytes)))
          .readMessage() as ParameterStatusMessage;

      expect(msg.parameter, 'client_encoding');
      expect(msg.value, 'UTF8');
    });

    test('Authentication MD5', () async {
      final payload = [
        ..._int32(AuthenticationRequestType.md5Password.code),
        1,
        2,
        3,
        4,
      ];
      final bytes =
          _frame(BackendMessageCode.authenticationRequest.typeCode, payload);

      final msg = await BackendMessageReader(
              PostgresMessageReader(MemoryBinaryInput(bytes)))
          .readMessage() as AuthenticationMD5PasswordMessage;

      expect(msg.authRequestType, AuthenticationRequestType.md5Password);
      expect(msg.salt, [1, 2, 3, 4]);
    });

    test('RowDescription', () async {
      final payload = BytesBuilder();
      payload.add(_int16(2)); // duas colunas

      void addField({
        required String name,
        required int tableOid,
        required int attrNum,
        required int oid,
        required int typeSize,
        required int typeModifier,
        required int format,
      }) {
        payload
          ..add(_cstring(name))
          ..add(_int32(tableOid))
          ..add(_int16(attrNum))
          ..add(_int32(oid))
          ..add(_int16(typeSize))
          ..add(_int32(typeModifier))
          ..add(_int16(format));
      }

      addField(
        name: 'id',
        tableOid: 42,
        attrNum: 1,
        oid: 23,
        typeSize: 4,
        typeModifier: -1,
        format: 0,
      );
      addField(
        name: 'name',
        tableOid: 42,
        attrNum: 2,
        oid: 25,
        typeSize: -1,
        typeModifier: -1,
        format: 1,
      );

      final bytes = _frame(
        BackendMessageCode.rowDescription.typeCode,
        payload.toBytes(),
      );

      final msg = await BackendMessageReader(
              PostgresMessageReader(MemoryBinaryInput(bytes)))
          .readMessage() as RowDescriptionMessage;

      expect(msg.fields, hasLength(2));
      expect(msg.fields[0].name, 'id');
      expect(msg.fields[0].format, DataFormat.text);
      expect(msg.fields[1].name, 'name');
      expect(msg.fields[1].format, DataFormat.binary);
    });

    test('DataRow', () async {
      final payload = BytesBuilder();
      payload.add(_int16(3));

      void addColumn(List<int>? data) {
        if (data == null) {
          payload.add(_int32(-1));
        } else {
          payload.add(_int32(data.length));
          payload.add(data);
        }
      }

      addColumn('ping'.codeUnits);
      addColumn(null);
      addColumn([0x01, 0x02]);

      final bytes =
          _frame(BackendMessageCode.dataRow.typeCode, payload.toBytes());

      final msg = await BackendMessageReader(
              PostgresMessageReader(MemoryBinaryInput(bytes)))
          .readMessage() as DataRowMessage;

      expect(msg.columns, hasLength(3));
      expect(msg.columns[0], 'ping'.codeUnits);
      expect(msg.columns[1], isNull);
      expect(msg.columns[2], [0x01, 0x02]);
    });

    test('ErrorResponse', () async {
      final payload = [
        0x53, // S
        ..._cstring('ERROR'),
        0x43, // C
        ..._cstring('12345'),
        0x4D, // M
        ..._cstring('falhou'),
        0x00,
      ];
      final bytes =
          _frame(BackendMessageCode.errorResponse.typeCode, payload);

      final msg = await BackendMessageReader(
              PostgresMessageReader(MemoryBinaryInput(bytes)))
          .readMessage() as ErrorResponseMessage;

      expect(msg.error.severity, 'ERROR');
      expect(msg.error.sqlState, '12345');
      expect(msg.error.messageText, 'falhou');
    });
  });
}

Uint8List _frame(int typeCode, List<int> payload) {
  final builder = BytesBuilder();
  builder.add([typeCode]);
  final bd = ByteData(4)..setInt32(0, payload.length + 4, Endian.big);
  builder.add(bd.buffer.asUint8List());
  builder.add(payload);
  return builder.toBytes();
}

List<int> _cstring(String value) => [...value.codeUnits, 0];

List<int> _int16(int value) {
  final bd = ByteData(2)..setInt16(0, value, Endian.big);
  return bd.buffer.asUint8List();
}

List<int> _int32(int value) {
  final bd = ByteData(4)..setInt32(0, value, Endian.big);
  return bd.buffer.asUint8List();
}
