import 'npgsql_batch.dart';
import 'npgsql_binary_exporter.dart';
import 'npgsql_binary_importer.dart';
import 'npgsql_command.dart';
import 'npgsql_data_reader.dart';
import 'npgsql_parameter_collection.dart';
import 'npgsql_transaction.dart';
import 'internal/npgsql_connector.dart';

enum ConnectionState { closed, open, connecting, executing, fetching }

/// Represents an open connection to a PostgreSQL database.
/// Porting NpgsqlConnection.cs
class NpgsqlConnection {
  NpgsqlConnection(this.connectionString) : _returnToPoolAction = null;

  final String connectionString;
  NpgsqlConnector? _connector;
  ConnectionState _state = ConnectionState.closed;

  ConnectionState get state => _state;

  /// Creates and returns a NpgsqlCommand object associated with the current connection.
  NpgsqlCommand createCommand(String commandText) {
    return NpgsqlCommand(commandText, this);
  }

  NpgsqlConnection.fromConnector(this._connector, this._returnToPoolAction)
      : connectionString = '',
        _state = ConnectionState.open;

  final void Function(NpgsqlConnector)? _returnToPoolAction;

  /// Opens a database connection with the property settings specified by the ConnectionString.
  Future<void> open() async {
    if (_state != ConnectionState.closed) {
      throw StateError('Connection already open or connecting');
    }

    _state = ConnectionState.connecting;

    try {
      final settings = _parseConnectionString(connectionString);

      _connector = NpgsqlConnector(
        host: settings['Host'] ?? 'localhost',
        port: int.parse(settings['Port'] ?? '5432'),
        username: settings['Username'] ?? settings['User ID'] ?? 'postgres',
        password: settings['Password'] ?? '',
        database: settings['Database'] ?? 'postgres',
      );

      await _connector!.open();
      _state = ConnectionState.open;
    } catch (e) {
      _state = ConnectionState.closed;
      _connector = null;
      rethrow;
    }
  }

  /// Closes the connection to the database.
  Future<void> close() async {
    if (_connector != null) {
      if (_returnToPoolAction != null) {
        _returnToPoolAction(_connector!);
      } else {
        await _connector!.close();
      }
      _connector = null;
    }
    _state = ConnectionState.closed;
  }

  /// Cancels the execution of the current command.
  Future<void> cancel() async {
    if (_connector == null) return;
    await _connector!.cancelRequest();
  }

  /// Begins a database transaction.
  Future<NpgsqlTransaction> beginTransaction(
      [String isolationLevel = '']) async {
    if (_connector == null) throw StateError('Connection closed');

    // Start transaction command
    var sql = 'BEGIN';
    if (isolationLevel.isNotEmpty) {
      sql += ' ISOLATION LEVEL $isolationLevel';
    }

    final reader = await executeReader(sql);
    await reader.close();

    return NpgsqlTransaction(this, isolationLevel);
  }

  Future<NpgsqlDataReader> executeReader(String commandText,
      {NpgsqlParameterCollection? parameters, String? statementName}) async {
    if (_connector == null) {
      throw StateError('Connection closed');
    }
    return _connector!.executeReader(commandText,
        parameters: parameters, statementName: statementName);
  }

  Future<void> prepare(String commandText, String statementName,
      NpgsqlParameterCollection parameters) async {
    if (_connector == null) throw StateError('Connection closed');
    await _connector!.prepare(commandText, statementName, parameters);
  }

  /// Starts a binary COPY FROM STDIN operation.
  Future<NpgsqlBinaryImporter> beginBinaryImport(String copyFromCommand) async {
    if (_connector == null) throw StateError('Connection closed');
    final importer = NpgsqlBinaryImporter(_connector!, copyFromCommand);
    await importer.init();
    return importer;
  }

  /// Starts a binary COPY TO STDOUT operation.
  Future<NpgsqlBinaryExporter> beginBinaryExport(String copyToCommand) async {
    if (_connector == null) throw StateError('Connection closed');
    final exporter = NpgsqlBinaryExporter(_connector!, copyToCommand);
    await exporter.init();
    return exporter;
  }

  NpgsqlBatch createBatch() {
    return NpgsqlBatch(this);
  }

  Future<NpgsqlDataReader> executeBatch(NpgsqlBatch batch) {
    if (_state != ConnectionState.open) {
      throw StateError('Connection is not open');
    }
    // We need to implement executeBatch in NpgsqlConnector
    return _connector!.executeBatch(batch);
  }

  // TODO: Move to a proper ConnectionStringBuilder/Parser class
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
