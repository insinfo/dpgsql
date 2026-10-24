// An error aborts a PostgreSQL transaction: the server answers its COMMIT
// with a ROLLBACK, not with an error. commit() must throw instead of letting
// the caller take the rolled back writes for saved.
import 'package:dpgsql/dpgsql.dart';
import 'package:test/test.dart';

import 'test_config.dart';

void main() {
  late DpgsqlConnection conn;
  var available = true;

  setUp(() async {
    final opened = await openRealConnectionOrSkip();
    if (opened == null) {
      available = false;
      return;
    }
    conn = opened;
    await conn
        .createCommand('CREATE TEMP TABLE aborted_commit (id int primary key)')
        .executeNonQuery();
  });

  tearDown(() async {
    if (available) await conn.close();
  });

  Future<void> insert(int id) => conn
      .createCommand('INSERT INTO aborted_commit VALUES ($id)')
      .executeNonQuery();

  Future<Object?> count() =>
      executeScalar(conn, 'SELECT count(*)::int FROM aborted_commit');

  test('commit after a caught error throws 25P02 and rolls back', () async {
    if (!available) return;
    final tx = await conn.beginTransaction();
    await insert(1);
    await expectLater(insert(1), throwsA(isA<PostgresException>()));
    expect(conn.transactionStatus, TransactionStatus.inFailedTransactionBlock);

    await expectLater(
        tx.commit(),
        throwsA(isA<PostgresException>()
            .having((e) => e.sqlState, 'sqlState', '25P02')));
    expect(tx.isCompleted, isTrue);
    expect(conn.transactionStatus, TransactionStatus.idle);
    expect(await count(), 0);
  });

  test('a ROLLBACK TO SAVEPOINT recovers: commit keeps the writes', () async {
    if (!available) return;
    final tx = await conn.beginTransaction();
    await insert(1);
    await tx.save('sp');
    await expectLater(insert(1), throwsA(isA<PostgresException>()));
    await tx.rollbackTo('sp');
    expect(conn.transactionStatus, TransactionStatus.inTransactionBlock);
    await insert(2);
    await tx.commit();
    expect(await count(), 2);
  });

  test('runInTransaction with a caught error throws and saves nothing',
      () async {
    if (!available) return;
    await expectLater(conn.runInTransaction((tx) async {
      await insert(1);
      try {
        await insert(1);
      } on PostgresException catch (_) {}
    }), throwsA(isA<PostgresException>()));
    expect(await count(), 0);
    expect(await executeScalar(conn, 'SELECT 1::int'), 1);
  });

  test('the status follows prepared commands too', () async {
    if (!available) return;
    final tx = await conn.beginTransaction();
    final cmd = conn.createCommand('SELECT 1 / @d AS r');
    cmd.parameters.addWithValue('d', 0);
    await expectLater(cmd.executeScalar(), throwsA(isA<PostgresException>()));
    expect(conn.transactionStatus, TransactionStatus.inFailedTransactionBlock);
    await expectLater(tx.commit(), throwsA(isA<PostgresException>()));
  });
}
