import 'dart:async';
import 'dart:collection';

import 'npgsql_connection.dart';
import 'internal/npgsql_connector.dart';

/// Represents a source of NpgsqlConnections.
/// Porting NpgsqlDataSource.cs
class NpgsqlDataSource {
  NpgsqlDataSource(this.connectionString);

  final String connectionString;
  final Queue<NpgsqlConnector> _idleConnectors = Queue<NpgsqlConnector>();
  final List<NpgsqlConnector> _busyConnectors = [];

  // Basic locking not needed in Dart due to single-threaded event loop?
  // But we have async gaps.
  // Actually we need to be careful not to checkout same connector twice.
  // Queue.removeFirst is synchronous.

  Future<NpgsqlConnection> openConnection() async {
    NpgsqlConnector? connector;

    while (_idleConnectors.isNotEmpty) {
      final c = _idleConnectors.removeFirst();
      if (c.isConnected) {
        connector = c;
        break;
      }
      // If not connected, discard it.
      // Ideally we would ensure it is closed regardless.
      try {
        await c.close();
      } catch (_) {}
    }

    // If not found in pool or pool empty
    if (connector == null) {
      final map = _parseConnectionString(connectionString);
      connector = NpgsqlConnector(
        host: map['Host'] ?? 'localhost',
        port: int.parse(map['Port'] ?? '5432'),
        username: map['Username'] ?? map['User ID'] ?? 'postgres',
        password: map['Password'] ?? '',
        database: map['Database'] ?? 'postgres',
      );
      await connector.open();
    }

    _busyConnectors.add(connector);

    // Create Connection wrapping this connector
    // We need internal API on NpgsqlConnection to accept an existing connector
    // and a callback to return it to pool on close.
    // Since NpgsqlConnection._connector is private and there is no constructor for it, we might need to modify NpgsqlConnection.
    return NpgsqlConnection.fromConnector(connector, _returnConnector);
  }

  void _returnConnector(NpgsqlConnector connector) {
    _busyConnectors.remove(connector);
    _idleConnectors.add(connector);
    // Reset state?
    // Rollback transaction if open?
    // For now simple return.
  }

  // TODO: Deduplicate this parser
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
}
