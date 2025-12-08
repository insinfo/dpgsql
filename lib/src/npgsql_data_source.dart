import 'dart:async';
import 'dart:collection';

import 'npgsql_connection.dart';
import 'internal/npgsql_connector.dart';
import 'npgsql_connection_string_builder.dart';

/// Represents a source of data for Npgsql, which can be used to create connections.
/// Typically handles connection pooling.
class NpgsqlDataSource {
  NpgsqlDataSource(this.connectionString);

  final String connectionString;
  final Queue<NpgsqlConnector> _idleConnectors = Queue<NpgsqlConnector>();

  // TODO: Max pool size, Min pool size, Timeout

  /// Opens a new connection to the database.
  Future<NpgsqlConnection> openConnection() async {
    NpgsqlConnector? connector;

    while (_idleConnectors.isNotEmpty) {
      connector = _idleConnectors.removeLast();
      if (connector.isConnected) {
        // TODO: Validate connection (e.g. SELECT 1 or check state)
        break;
      } else {
        // Prune disconnected
        connector = null;
      }
    }

    if (connector == null) {
      connector = _createConnector();
      await connector.open();
    }

    return NpgsqlConnection.fromConnector(connector, _returnConnector);
  }

  void _returnConnector(NpgsqlConnector connector) {
    if (connector.isConnected) {
      // Reset state? (Rollback transaction if any, close portals)
      // For now, just add back.
      _idleConnectors.add(connector);
    }
  }

  NpgsqlConnector _createConnector() {
    final builder = NpgsqlConnectionStringBuilder(connectionString);
    return NpgsqlConnector(
      host: builder.host,
      port: builder.port,
      username: builder.username,
      password: builder.password,
      database: builder.database,
      sslMode: builder.sslMode,
      trustServerCertificate: builder.trustServerCertificate,
      encoding: builder.encoding,
      // Replication not exposed in standard DataSource connection strings usually,
      // unless specific params.
    );
  }

  Future<void> dispose() async {
    for (final c in _idleConnectors) {
      await c.close();
    }
    _idleConnectors.clear();
  }
}
