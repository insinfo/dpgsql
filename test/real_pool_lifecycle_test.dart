import 'package:dpgsql/dpgsql.dart';
import 'package:test/test.dart';

import 'test_config.dart';

void main() {
  test('pooled physical connection keeps auto-prepared statements reusable',
      () async {
    final probe = await openRealConnectionOrSkip();
    if (probe == null) return;
    await probe.close();

    final dataSource = NpgsqlDataSource(realConnectionString(
      options:
          'Maximum Pool Size=1;Max Auto Prepare=2;Auto Prepare Min Usages=1',
    ));

    try {
      var conn = await dataSource.openConnection();
      expect(
        await executeScalar(conn, 'SELECT @value::int + 10', {'value': 32}),
        equals(42),
      );
      await conn.close();

      conn = await dataSource.openConnection();
      try {
        final preparedCount = await executeScalar(
          conn,
          r"SELECT count(*)::int FROM pg_prepared_statements WHERE name LIKE '\_p%' ESCAPE '\'",
        );
        expect(preparedCount, greaterThanOrEqualTo(1));

        expect(
          await executeScalar(conn, 'SELECT @value::int + 10', {'value': 33}),
          equals(43),
        );
      } finally {
        await conn.close();
      }
    } finally {
      await dataSource.dispose();
    }
  });
}
