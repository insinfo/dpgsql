import 'dpgsql_connection_string_builder.dart';
import 'dpgsql_data_source.dart';

/// Fluent builder for [DpgsqlDataSource].
///
/// This mirrors the Npgsql data source builder shape while keeping the Dart
/// implementation deliberately small. Advanced hooks such as logging,
/// OpenTelemetry, password providers, and type mapper plugins will hang off
/// this class as those subsystems are ported.
class DpgsqlDataSourceBuilder {
  DpgsqlDataSourceBuilder([String? connectionString])
      : connectionStringBuilder =
            DpgsqlConnectionStringBuilder(connectionString);

  /// Mutable connection string builder used to configure the data source.
  final DpgsqlConnectionStringBuilder connectionStringBuilder;

  /// Called after each physical connection is opened and after configured
  /// session settings from the connection string are applied.
  DpgsqlConnectionCallback? onOpen;

  /// Canonical connection string produced from [connectionStringBuilder].
  String get connectionString => connectionStringBuilder.toString();

  /// Allows concise mutation while preserving a fluent builder style.
  DpgsqlDataSourceBuilder configureConnectionString(
    void Function(DpgsqlConnectionStringBuilder builder) configure,
  ) {
    configure(connectionStringBuilder);
    return this;
  }

  DpgsqlDataSourceBuilder configureOnOpen(
    DpgsqlConnectionCallback? callback,
  ) {
    onOpen = callback;
    return this;
  }

  /// Builds a data source using the current connection string settings.
  DpgsqlDataSource build() => DpgsqlDataSource.fromConnectionStringBuilder(
        connectionStringBuilder,
        onOpen: onOpen,
      );
}
