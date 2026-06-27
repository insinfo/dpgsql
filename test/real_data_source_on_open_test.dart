import 'package:dpgsql/dpgsql.dart';
import 'package:test/test.dart';

import 'test_config.dart';

void main() {
  test('connection builder applies configured session settings', () async {
    final probe = await openRealConnectionOrSkip();
    if (probe == null) return;
    await probe.close();

    final settings = DpgsqlConnectionStringBuilder(realConnectionString())
      ..searchPath = 'public'
      ..applicationName = 'dpgsql-session-settings-test'
      ..statementTimeout = '7s'
      ..lockTimeout = '3s'
      ..idleInTransactionSessionTimeout = '11s';

    final connection = DpgsqlConnection.fromConnectionStringBuilder(settings);
    try {
      await connection.open();
      expect(await connection.executeScalar('SHOW search_path'), 'public');
      expect(
        await connection
            .executeScalar("SELECT current_setting('application_name')"),
        'dpgsql-session-settings-test',
      );
      expect(await connection.executeScalar('SHOW statement_timeout'), '7s');
      expect(await connection.executeScalar('SHOW lock_timeout'), '3s');
      expect(
        await connection
            .executeScalar('SHOW idle_in_transaction_session_timeout'),
        '11s',
      );
    } finally {
      await connection.close();
    }
  });

  test('data source onOpen configures pooled physical connection session',
      () async {
    final probe = await openRealConnectionOrSkip();
    if (probe == null) return;
    await probe.close();

    var openCount = 0;
    final dataSource = DpgsqlDataSourceBuilder(
      realConnectionString(
        options: 'Pooling=true;Minimum Pool Size=1;Maximum Pool Size=1;'
            'No Reset On Close=true;Encoding=LATIN1;Client Encoding=UTF8',
      ),
    ).configureOnOpen((connection) async {
      openCount++;
      await connection
          .createCommand("SET client_encoding = 'LATIN1'")
          .executeNonQuery();
      await connection
          .createCommand("SET TIME ZONE 'America/Sao_Paulo'")
          .executeNonQuery();
    }).build();

    try {
      await dataSource.warmup();
      expect(openCount, 1);

      await _expectSessionSettings(dataSource);
      await _expectSessionSettings(dataSource);

      expect(
        openCount,
        1,
        reason: 'The same physical pooled connection should be reused.',
      );
    } finally {
      await dataSource.dispose();
    }
  });
}

Future<void> _expectSessionSettings(DpgsqlDataSource dataSource) async {
  final connection = await dataSource.openConnection();
  try {
    expect(
      await connection.executeScalar('SHOW client_encoding'),
      'LATIN1',
    );
    expect(
      await connection.executeScalar("SELECT 'Café'::text"),
      'Café',
    );
    expect(
      await connection.executeScalar("SELECT current_setting('TimeZone')"),
      'America/Sao_Paulo',
    );
  } finally {
    await connection.close();
  }
}
