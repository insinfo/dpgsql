import 'package:dpgsql/dpgsql.dart';
import 'package:test/test.dart';

void main() {
  test('DpgsqlDataSourceBuilder builds data source from mutable settings', () {
    final builder = DpgsqlDataSourceBuilder('Host=localhost;Port=5432')
      ..configureConnectionString((settings) {
        settings.database = 'dart_test';
        settings.username = 'dart';
        settings.password = 'secret';
        settings.maxPoolSize = 7;
      });

    final dataSource = builder.build();

    expect(dataSource.connectionString, contains('Host=localhost;'));
    expect(dataSource.connectionString, contains('Port=5432;'));
    expect(dataSource.connectionString, contains('Database=dart_test;'));
    expect(dataSource.connectionString, contains('Username=dart;'));
    expect(dataSource.connectionString, contains('Password=secret;'));
    expect(dataSource.maxPoolSize, 7);
  });

  test('DpgsqlSlimDataSourceBuilder preserves Npgsql-like builder shape', () {
    final slim = DpgsqlSlimDataSourceBuilder()
      ..configureConnectionString((settings) {
        settings.host = '127.0.0.1';
        settings.port = 15432;
        settings.pooling = false;
      });

    final dataSource = slim.build();

    expect(dataSource.connectionString, contains('Host=127.0.0.1;'));
    expect(dataSource.connectionString, contains('Port=15432;'));
    expect(dataSource.pooling, isFalse);
    expect(slim.toDataSourceBuilder().connectionString,
        equals(slim.connectionString));
  });

  test('DpgsqlFactory creates common provider objects', () {
    const factory = DpgsqlFactory.instance;

    expect(factory.createCommand('SELECT 1').commandText, 'SELECT 1');
    expect(factory.createConnection('Host=localhost').connectionString,
        'Host=localhost');
    expect(factory.createConnectionStringBuilder('Host=db').host, 'db');
    expect(factory.createDataSource('Host=localhost'), isA<DpgsqlDataSource>());
    expect(factory.createDataSourceBuilder('Host=localhost'),
        isA<DpgsqlDataSourceBuilder>());
    expect(factory.createSlimDataSourceBuilder('Host=localhost'),
        isA<DpgsqlSlimDataSourceBuilder>());
    expect(factory.createCommandBuilder(), isA<DpgsqlCommandBuilder>());
    expect(factory.createDataAdapter(), isA<DpgsqlDataAdapter>());
    expect(factory.createMetricsOptions(), isA<DpgsqlMetricsOptions>());
  });

  test('DpgsqlDataSource exposes static creation helpers', () {
    final builder = DpgsqlConnectionStringBuilder('Host=localhost')
      ..database = 'dart_test';

    expect(DpgsqlDataSource.create('Host=localhost'), isA<DpgsqlDataSource>());
    expect(DpgsqlDataSource.createFromBuilder(builder).connectionString,
        contains('Database=dart_test;'));
  });
}
