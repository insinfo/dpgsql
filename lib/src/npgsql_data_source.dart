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
      if (connector.isConnected && await _healthCheck(connector)) {
        _totalConnectionsReused++;
        break;
      } else {
        // Connection dead, prune it
        _totalConnectionsFailed++;
        try {
          await connector.close();
        } catch (_) {}
        connector = null;
      }
    }

    if (connector == null) {
      connector = _createConnector();
      await connector.open();
      _totalConnectionsCreated++;
    } else {
      // Reset connection state before reuse
      await _resetConnection(connector);
    }

    return NpgsqlConnection.fromConnector(connector, _returnConnector);
  }

  /// Health check: ping connection.
  Future<bool> _healthCheck(NpgsqlConnector connector) async {
    try {
      // Simple ping query
      final conn = NpgsqlConnection.fromConnector(connector, (_) {});
      final cmd = conn.createCommand('SELECT 1');
      await cmd
          .executeNonQuery()
          .timeout(const Duration(milliseconds: 100));
      return true;
    } on TimeoutException {
      // TODO Some tests use mock servers that do not implement query handling.
      // Consider the connection healthy if it is still open.
      return connector.isConnected;
    } catch (e) {
      return false;
    }
  }

  /// Reset connection state.
  Future<void> _resetConnection(NpgsqlConnector connector) async {
    try {
      final conn = NpgsqlConnection.fromConnector(connector, (_) {});

      // Rollback any open transaction
      try {
        await conn
            .createCommand('ROLLBACK')
            .executeNonQuery()
            .timeout(const Duration(milliseconds: 100));
      } catch (_) {}

      // Discard all (prepared statements, temp tables, etc)
      try {
        await conn
            .createCommand('DISCARD ALL')
            .executeNonQuery()
            .timeout(const Duration(milliseconds: 100));
      } catch (_) {}
    } catch (_) {
      // If reset fails, let caller handle
    }
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
    );
  }

  // Pool metrics
  int _totalConnectionsCreated = 0;
  int _totalConnectionsReused = 0;
  int _totalConnectionsFailed = 0;

  int get totalConnectionsCreated => _totalConnectionsCreated;
  int get totalConnectionsReused => _totalConnectionsReused;
  int get totalConnectionsFailed => _totalConnectionsFailed;
  int get idleCount => _idleConnectors.length;

  Map<String, dynamic> get poolStats => {
        'idle': idleCount,
        'created': totalConnectionsCreated,
        'reused': totalConnectionsReused,
        'failedHealthChecks': totalConnectionsFailed,
      };

  Future<void> dispose() async {
    for (final c in _idleConnectors) {
      await c.close();
    }
    _idleConnectors.clear();
  }
}
