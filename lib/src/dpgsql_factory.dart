import 'dpgsql_command.dart';
import 'dpgsql_command_builder.dart';
import 'dpgsql_connection.dart';
import 'dpgsql_connection_string_builder.dart';
import 'dpgsql_data_adapter.dart';
import 'dpgsql_data_source.dart';
import 'dpgsql_data_source_builder.dart';
import 'dpgsql_metrics_options.dart';
import 'dpgsql_slim_data_source_builder.dart';

/// Factory for creating dpgsql public API objects.
///
/// This is the Dart equivalent of NpgsqlFactory's common creation surface.
class DpgsqlFactory {
  const DpgsqlFactory();

  static const DpgsqlFactory instance = DpgsqlFactory();

  DpgsqlCommand createCommand([String commandText = '']) {
    return DpgsqlCommand(commandText);
  }

  DpgsqlCommandBuilder createCommandBuilder([
    DpgsqlDataAdapter? adapter,
  ]) {
    return DpgsqlCommandBuilder(adapter);
  }

  DpgsqlConnection createConnection([String connectionString = '']) {
    return DpgsqlConnection(connectionString);
  }

  DpgsqlConnectionStringBuilder createConnectionStringBuilder([
    String? connectionString,
  ]) {
    return DpgsqlConnectionStringBuilder(connectionString);
  }

  DpgsqlDataSource createDataSource(String connectionString) {
    return DpgsqlDataSource(connectionString);
  }

  DpgsqlDataSourceBuilder createDataSourceBuilder([
    String? connectionString,
  ]) {
    return DpgsqlDataSourceBuilder(connectionString);
  }

  DpgsqlSlimDataSourceBuilder createSlimDataSourceBuilder([
    String? connectionString,
  ]) {
    return DpgsqlSlimDataSourceBuilder(connectionString);
  }

  DpgsqlDataAdapter createDataAdapter([
    DpgsqlCommand? selectCommand,
  ]) {
    return DpgsqlDataAdapter(selectCommand);
  }

  DpgsqlMetricsOptions createMetricsOptions() {
    return const DpgsqlMetricsOptions();
  }
}
