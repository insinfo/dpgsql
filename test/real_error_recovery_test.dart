import 'package:dpgsql/dpgsql.dart';
import 'package:test/test.dart';

import 'test_config.dart';

void main() {
  test('real connection remains usable after PostgreSQL ErrorResponse',
      () async {
    final conn = await openRealConnectionOrSkip();
    if (conn == null) return;

    try {
      try {
        await conn
            .createCommand('SELECT missing_column FROM (SELECT 1) AS t')
            .executeNonQuery();
        fail('Expected PostgreSQL to report undefined_column.');
      } on PostgresException catch (e) {
        expect(e.sqlState, equals('42703'));
        expect(e.messageText, contains('missing_column'));
      }

      expect(await executeScalar(conn, 'SELECT 42::int'), equals(42));
    } finally {
      await conn.close();
    }
  });

  test('real transaction can rollback after command failure', () async {
    final conn = await openRealConnectionOrSkip();
    if (conn == null) return;

    try {
      final tx = await conn.beginTransaction();
      try {
        await conn
            .createCommand('SELECT missing_column FROM (SELECT 1) AS t')
            .executeNonQuery();
        fail('Expected PostgreSQL to report undefined_column.');
      } on PostgresException catch (e) {
        expect(e.sqlState, equals('42703'));
      }

      await tx.rollback();
      expect(await executeScalar(conn, 'SELECT 7::int'), equals(7));
    } finally {
      await conn.close();
    }
  });
}
