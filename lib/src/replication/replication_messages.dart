/// Base class for Logical Replication messages.
abstract class ReplicationMessage {
  ReplicationMessageCode get code;
}

enum ReplicationMessageCode {
  begin(0x42), // 'B'
  commit(0x43), // 'C'
  origin(0x4F), // 'O'
  relation(0x52), // 'R'
  type(0x59), // 'Y'
  insert(0x49), // 'I'
  update(0x55), // 'U'
  delete(0x44), // 'D'
  truncate(0x54); // 'T'

  final int value;
  const ReplicationMessageCode(this.value);

  static ReplicationMessageCode fromValue(int value) {
    for (final c in values) {
      if (c.value == value) return c;
    }
    throw FormatException('Unknown replication message code: $value');
  }
}

class BeginMessage extends ReplicationMessage {
  final int xlogWalEnd;
  final DateTime commitTime;
  final int transactionXid;

  BeginMessage({
    required this.xlogWalEnd,
    required this.commitTime,
    required this.transactionXid,
  });

  @override
  ReplicationMessageCode get code => ReplicationMessageCode.begin;
}

class CommitMessage extends ReplicationMessage {
  final int flags;
  final int commitLsn;
  final int transactionEndLsn;
  final DateTime commitTime;

  CommitMessage({
    required this.flags,
    required this.commitLsn,
    required this.transactionEndLsn,
    required this.commitTime,
  });

  @override
  ReplicationMessageCode get code => ReplicationMessageCode.commit;
}

class RelationMessage extends ReplicationMessage {
  final int relationId;
  final String namespace;
  final String relationName;
  final int replicaIdentity; // 'd' default, 'n' nothing, 'f' full, 'i' index
  final List<RelationColumn> columns;

  RelationMessage({
    required this.relationId,
    required this.namespace,
    required this.relationName,
    required this.replicaIdentity,
    required this.columns,
  });

  @override
  ReplicationMessageCode get code => ReplicationMessageCode.relation;
}

class RelationColumn {
  final int flags; // 1 = Key
  final String name;
  final int dataTypeId;
  final int typeModifier;

  RelationColumn({
    required this.flags,
    required this.name,
    required this.dataTypeId,
    required this.typeModifier,
  });
}

class InsertMessage extends ReplicationMessage {
  final int relationId;
  final ReplicationTuple tuple;

  InsertMessage({required this.relationId, required this.tuple});

  @override
  ReplicationMessageCode get code => ReplicationMessageCode.insert;
}

class UpdateMessage extends ReplicationMessage {
  final int relationId;
  final ReplicationTuple? oldTuple; // 'O' or 'K'
  final ReplicationTuple newTuple; // 'N'

  UpdateMessage({
    required this.relationId,
    this.oldTuple,
    required this.newTuple,
  });

  @override
  ReplicationMessageCode get code => ReplicationMessageCode.update;
}

class DeleteMessage extends ReplicationMessage {
  final int relationId;
  final ReplicationTuple? oldTuple; // 'O' or 'K'

  DeleteMessage({required this.relationId, this.oldTuple});

  @override
  ReplicationMessageCode get code => ReplicationMessageCode.delete;
}

class ReplicationTuple {
  final List<ReplicationValue> columns;

  ReplicationTuple(this.columns);
}

class ReplicationValue {
  final ValueKind kind;
  final List<int>? data; // Bytes of text representation

  ReplicationValue(this.kind, this.data);

  bool get isNull => kind == ValueKind.nullValue;
  bool get isUnchanged => kind == ValueKind.unchanged;
  bool get isText => kind == ValueKind.text;
}

enum ValueKind {
  nullValue(0x6e), // 'n'
  unchanged(0x75), // 'u'
  text(0x74); // 't'

  final int value;
  const ValueKind(this.value);

  static ValueKind fromValue(int value) {
    for (final c in values) {
      if (c.value == value) return c;
    }
    throw FormatException('Unknown value kind: $value');
  }
}
