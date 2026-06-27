import 'dpgsql_connection_string_builder.dart';
import 'dpgsql_data_source.dart';
import 'dpgsql_data_source_builder.dart';

/// Minimal data source builder.
///
/// In Npgsql, the slim builder starts with fewer optional services configured.
/// dpgsql does not yet have those service graphs, so this class intentionally
/// shares the same behavior as [DpgsqlDataSourceBuilder] while preserving the
/// API shape for future ports.
class DpgsqlSlimDataSourceBuilder {
  DpgsqlSlimDataSourceBuilder([String? connectionString])
      : connectionStringBuilder =
            DpgsqlConnectionStringBuilder(connectionString);

  final DpgsqlConnectionStringBuilder connectionStringBuilder;

  String get connectionString => connectionStringBuilder.toString();

  DpgsqlSlimDataSourceBuilder configureConnectionString(
    void Function(DpgsqlConnectionStringBuilder builder) configure,
  ) {
    configure(connectionStringBuilder);
    return this;
  }

  DpgsqlDataSource build() => DpgsqlDataSource(connectionString);

  DpgsqlDataSourceBuilder toDataSourceBuilder() =>
      DpgsqlDataSourceBuilder(connectionString);
}
