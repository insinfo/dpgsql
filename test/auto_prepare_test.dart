import 'package:dpgsql/dpgsql.dart';
import 'package:test/test.dart';

import 'test_config.dart';

void main() {
  test('Auto prepare prepares at threshold and closes evicted statements',
      () async {
    final conn = await openRealConnectionOrSkip(
      options: 'Max Auto Prepare=1;Auto Prepare Min Usages=1',
    );
    if (conn == null) return;

    try {
      expect(
        await executeScalar(
          conn,
          'SELECT @value::int + 1',
          {'value': 41},
        ),
        equals(42),
      );

      expect(await _preparedStatementCount(conn), equals(1));

      expect(
        await executeScalar(
          conn,
          'SELECT @value::int + 2',
          {'value': 42},
        ),
        equals(44),
      );

      expect(await _preparedStatementCount(conn), equals(1));
      expect(await _singlePreparedStatement(conn), contains('+ 2'));
    } finally {
      await conn.close();
    }
  });
}

Future<int> _preparedStatementCount(NpgsqlConnection conn) async {
  return await executeScalar(
        conn,
        r"SELECT count(*)::int FROM pg_prepared_statements WHERE name LIKE '\_p%' ESCAPE '\'",
        const {},
      ) as int? ??
      0;
}

Future<String> _singlePreparedStatement(NpgsqlConnection conn) async {
  return await executeScalar(
        conn,
        r"SELECT statement FROM pg_prepared_statements WHERE name LIKE '\_p%' ESCAPE '\' ORDER BY name LIMIT 1",
        const {},
      ) as String? ??
      '';
}
