import 'dart:convert';
import 'dart:typed_data';
import 'package:dpgsql/src/replication/logical_replication_protocol.dart';
import 'package:dpgsql/src/replication/replication_messages.dart';
import 'package:test/test.dart';

void main() {
  group('Logical Replication Protocol', () {
    test('Parse Relation Message', () {
      final bytes = BytesBuilder();
      bytes.addByte(0x52); // 'R'
      bytes.add(_int32(12345)); // ID
      bytes.add(_cstring('public'));
      bytes.add(_cstring('users'));
      bytes.addByte(0x64); // Replica Identity 'd'
      bytes.add(_int16(2)); // Num Cols

      // Col 1: id, int4
      bytes.addByte(1); // Key flag
      bytes.add(_cstring('id'));
      bytes.add(_int32(23)); // int4 oid
      bytes.add(_int32(-1)); // mod

      // Col 2: name, text
      bytes.addByte(0);
      bytes.add(_cstring('name'));
      bytes.add(_int32(25)); // text oid
      bytes.add(_int32(-1));

      final msg =
          LogicalReplicationProtocol.parse(bytes.toBytes()) as RelationMessage;
      expect(msg.relationId, 12345);
      expect(msg.namespace, 'public');
      expect(msg.relationName, 'users');
      expect(msg.columns.length, 2);
      expect(msg.columns[0].name, 'id');
      expect(msg.columns[0].flags, 1);
      expect(msg.columns[1].name, 'name');
    });

    test('Parse Insert Message', () {
      final bytes = BytesBuilder();
      bytes.addByte(0x49); // 'I'
      bytes.add(_int32(12345));
      bytes.addByte(0x4E); // 'N'

      // Tuple Data
      bytes.add(_int16(2)); // Num Cols

      // Col 1: Text '42'
      bytes.addByte(0x74); // 't'
      bytes.add(_int32(2)); // Length
      bytes.add(_cstringRaw('42'));

      // Col 2: Null
      bytes.addByte(0x6E); // 'n'

      final msg =
          LogicalReplicationProtocol.parse(bytes.toBytes()) as InsertMessage;
      expect(msg.relationId, 12345);
      expect(msg.tuple.columns.length, 2);
      expect(msg.tuple.columns[0].kind, ValueKind.text);
      expect(utf8.decode(msg.tuple.columns[0].data!), '42');
      expect(msg.tuple.columns[1].kind, ValueKind.nullValue);
    });

    test('Parse Update Message', () {
      final bytes = BytesBuilder();
      bytes.addByte(0x55); // 'U'
      bytes.add(_int32(1));

      // Optional Old Tuple 'O' (Key)
      bytes.addByte(0x4F); // 'O'
      bytes.add(_int16(1));
      bytes.addByte(0x74);
      bytes.add(_int32(1));
      bytes.add(_cstringRaw('1'));

      // New Tuple 'N'
      bytes.addByte(0x4E); // 'N'
      bytes.add(_int16(1));
      bytes.addByte(0x74);
      bytes.add(_int32(1));
      bytes.add(_cstringRaw('2'));

      final msg =
          LogicalReplicationProtocol.parse(bytes.toBytes()) as UpdateMessage;
      expect(msg.relationId, 1);
      expect(msg.oldTuple, isNotNull);
      expect(msg.newTuple, isNotNull);
      expect(utf8.decode(msg.oldTuple!.columns[0].data!), '1');
      expect(utf8.decode(msg.newTuple.columns[0].data!), '2');
    });

    test('Parse Delete Message', () {
      final bytes = BytesBuilder();
      bytes.addByte(0x44); // 'D'
      bytes.add(_int32(100));

      // Old Tuple 'K' (Key)
      bytes.addByte(0x4B); // 'K'
      bytes.add(_int16(1));
      bytes.addByte(0x74);
      bytes.add(_int32(3));
      bytes.add(_cstringRaw('foo'));

      final msg =
          LogicalReplicationProtocol.parse(bytes.toBytes()) as DeleteMessage;
      expect(msg.relationId, 100);
      expect(msg.oldTuple, isNotNull);
      expect(utf8.decode(msg.oldTuple!.columns[0].data!), 'foo');
    });
  });
}

List<int> _int32(int value) {
  final bd = ByteData(4);
  bd.setInt32(0, value);
  return bd.buffer.asUint8List();
}

List<int> _int16(int value) {
  final bd = ByteData(2);
  bd.setInt16(0, value);
  return bd.buffer.asUint8List();
}

List<int> _cstring(String s) {
  final b = utf8.encode(s).toList();
  b.add(0);
  return b;
}

List<int> _cstringRaw(String s) {
  return utf8.encode(s);
}
