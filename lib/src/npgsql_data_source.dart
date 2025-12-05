import 'dart:async';
import 'dart:collection';

import 'ssl_mode.dart';
import 'npgsql_connection.dart';
import 'internal/npgsql_connector.dart';

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
    final settings = _parseConnectionString(connectionString);
    return NpgsqlConnector(
      host: settings['Host'] ?? 'localhost',
      port: int.parse(settings['Port'] ?? '5432'),
      username: settings['Username'] ?? settings['User ID'] ?? 'postgres',
      password: settings['Password'] ?? '',
      database: settings['Database'] ?? 'postgres',
      sslMode: _parseSslMode(settings['SSL Mode'] ?? settings['SslMode']),
    );
  }

  Map<String, String> _parseConnectionString(String connString) {
    final map = <String, String>{};
    final parts = connString.split(';');
    for (final part in parts) {
      final kv = part.split('=');
      if (kv.length == 2) {
        final key = kv[0].trim();
        final value = kv[1].trim();
        map[key] = value;
      }
    }
    return map;
  }

  SslMode _parseSslMode(String? value) {
    if (value == null) return SslMode.disable;
    switch (value.toLowerCase()) {
      case 'disable':
        return SslMode.disable;
      case 'allow':
        return SslMode.allow;
      case 'prefer':
        return SslMode.prefer;
      case 'require':
        return SslMode.require;
      default:
        return SslMode.disable;
    }
  }

  Future<void> dispose() async {
    for (final c in _idleConnectors) {
      await c.close();
    }
    _idleConnectors.clear();
  }
}
