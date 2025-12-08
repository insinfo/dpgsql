import 'dart:convert';
import 'dart:typed_data';
import 'replication_messages.dart';
import '../io/binary_input.dart';

class LogicalReplicationProtocol {
  static final DateTime _pgEpoch = DateTime.utc(2000, 1, 1);

  static ReplicationMessage parse(Uint8List data) {
    final input = MemoryBinaryInput(data);
    final codeValue = input.readUint8();
    final code = ReplicationMessageCode.fromValue(codeValue);

    switch (code) {
      case ReplicationMessageCode.begin:
        return _parseBegin(input);
      case ReplicationMessageCode.commit:
        return _parseCommit(input);
      case ReplicationMessageCode.relation:
        return _parseRelation(input);
      case ReplicationMessageCode.insert:
        return _parseInsert(input);
      case ReplicationMessageCode.update:
        return _parseUpdate(input);
      case ReplicationMessageCode.delete:
        return _parseDelete(input);
      default:
        // For now, treat unknown as just message code or throw,
        // but to avoid crashing stream, maybe unexpected?
        throw UnimplementedError('Replication message $code not supported yet');
    }
  }

  static BeginMessage _parseBegin(BinaryInput input) {
    final lsn = input.readInt64();
    final timestampMicros = input.readInt64();
    final xid = input.readInt32();
    final commitTime = _pgEpoch.add(Duration(microseconds: timestampMicros));
    return BeginMessage(
      xlogWalEnd: lsn,
      commitTime: commitTime,
      transactionXid: xid,
    );
  }

  static CommitMessage _parseCommit(BinaryInput input) {
    final flags = input.readUint8();
    final commitLsn = input.readInt64();
    final endLsn = input.readInt64();
    final timestampMicros = input.readInt64();
    final commitTime = _pgEpoch.add(Duration(microseconds: timestampMicros));
    return CommitMessage(
      flags: flags,
      commitLsn: commitLsn,
      transactionEndLsn: endLsn,
      commitTime: commitTime,
    );
  }

  static RelationMessage _parseRelation(BinaryInput input) {
    final relId = input.readInt32();
    final namespace = _readCString(input);
    final relationName = _readCString(input);
    final replicaIdentity = input.readUint8();
    final numColumns = input.readInt16();

    final columns = <RelationColumn>[];
    for (var i = 0; i < numColumns; i++) {
      final flags = input.readUint8();
      final name = _readCString(input);
      final dataTypeId = input.readInt32();
      final typeMod = input.readInt32();
      columns.add(RelationColumn(
        flags: flags,
        name: name,
        dataTypeId: dataTypeId,
        typeModifier: typeMod,
      ));
    }

    return RelationMessage(
      relationId: relId,
      namespace: namespace,
      relationName: relationName,
      replicaIdentity: replicaIdentity,
      columns: columns,
    );
  }

  static InsertMessage _parseInsert(BinaryInput input) {
    final relId = input.readInt32();
    final charN = input.readUint8(); // 'N'
    if (charN != 0x4E) {
      throw FormatException(
          'Expected New Tuple (N) in Insert message, got $charN');
    }
    final tuple = _parseTuple(input);
    return InsertMessage(relationId: relId, tuple: tuple);
  }

  static UpdateMessage _parseUpdate(BinaryInput input) {
    final relId = input.readInt32();

    // Check for optional old tuple
    // Next char determines kind: 'O' (Old key), 'K' (Key), 'N' (New)
    // Actually standard says:
    // Byte1('O') | Byte1('K') | Byte1('N')
    // If 'O' or 'K', we read old tuple.
    // Then we read 'N' and new tuple.

    // We need to peek or just read byte.
    // Since BinaryInput doesn't peek easily, we read and decide.
    // This assumes the order 'O'/'K' then 'N'.

    int kind = input.readUint8();
    ReplicationTuple? oldTuple;

    if (kind == 0x4F || kind == 0x4B) {
      // 'O' or 'K'
      oldTuple = _parseTuple(input);
      kind = input.readUint8(); // Read next, should be 'N'
    }

    if (kind != 0x4E) {
      // 'N'
      throw FormatException(
          'Expected New Tuple (N) in Update message, got $kind');
    }

    final newTuple = _parseTuple(input);
    return UpdateMessage(
        relationId: relId, oldTuple: oldTuple, newTuple: newTuple);
  }

  static DeleteMessage _parseDelete(BinaryInput input) {
    final relId = input.readInt32();
    final kind = input.readUint8(); // 'O' or 'K'
    if (kind != 0x4F && kind != 0x4B) {
      throw FormatException(
          'Expected Old Tuple (O/K) in Delete message, got $kind');
    }
    final oldTuple = _parseTuple(input);
    return DeleteMessage(relationId: relId, oldTuple: oldTuple);
  }

  static ReplicationTuple _parseTuple(BinaryInput input) {
    final numColumns = input.readInt16();
    final values = <ReplicationValue>[];

    for (var i = 0; i < numColumns; i++) {
      final kindValue = input.readUint8();
      final kind = ValueKind.fromValue(kindValue);
      List<int>? data;

      if (kind == ValueKind.text) {
        final len = input.readInt32();
        data = input.readBytes(len);
      }

      values.add(ReplicationValue(kind, data));
    }

    return ReplicationTuple(values);
  }

  static String _readCString(BinaryInput input) {
    final bytes = <int>[];
    while (true) {
      final b = input.readUint8();
      if (b == 0) break;
      bytes.add(b);
    }
    return utf8.decode(bytes);
  }
}
