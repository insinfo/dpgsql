import 'dart:async';
import 'dart:typed_data';

import 'npgsql_connection.dart';
import 'npgsql_large_object_stream.dart';

/// Large object manager. This class can be used to store very large files in a PostgreSQL database.
/// Porting NpgsqlLargeObjectManager.cs
class NpgsqlLargeObjectManager {
  NpgsqlLargeObjectManager(this._connection);

  final NpgsqlConnection _connection;

  // PostgreSQL Large Object function OIDs
  static const int _INV_READ = 0x00040000;
  static const int _INV_WRITE = 0x00020000;

  /// Execute a function and return an int result.
  Future<int> _executeFunction(String functionName, List<Object?> args) async {
    final argPlaceholders =
        List.generate(args.length, (i) => '\$${i + 1}').join(', ');
    final sql = 'SELECT $functionName($argPlaceholders)';

    final cmd = _connection.createCommand(sql);
    for (int i = 0; i < args.length; i++) {
      cmd.parameters.addWithValue('p$i', args[i]);
    }

    final reader = await cmd.executeReader();
    try {
      if (await reader.read()) {
        final result = reader.getValue(0);
        if (result is int) return result;
        if (result is BigInt) return result.toInt();
        throw Exception(
            'Unexpected result type from $functionName: ${result.runtimeType}');
      }
      throw Exception('No result from $functionName');
    } finally {
      await reader.close();
    }
  }

  /// Execute a function that returns a byte array.
  Future<Uint8List> _executeFunctionGetBytes(
      String functionName, List<Object?> args) async {
    final argPlaceholders =
        List.generate(args.length, (i) => '\$${i + 1}').join(', ');
    final sql = 'SELECT $functionName($argPlaceholders)';

    final cmd = _connection.createCommand(sql);
    for (int i = 0; i < args.length; i++) {
      cmd.parameters.addWithValue('p$i', args[i]);
    }

    final reader = await cmd.executeReader();
    try {
      if (await reader.read()) {
        final result = reader.getValue(0);
        if (result is Uint8List) return result;
        if (result == null) return Uint8List(0);
        throw Exception(
            'Unexpected result type from $functionName: ${result.runtimeType}');
      }
      throw Exception('No result from $functionName');
    } finally {
      await reader.close();
    }
  }

  /// Create an empty large object in the database.
  /// If [preferredOid] is specified but is already in use, a PostgresException will be thrown.
  /// Returns the oid for the large object created.
  Future<int> create([int preferredOid = 0]) async {
    return _executeFunction('lo_create', [preferredOid]);
  }

  /// Opens a large object on the backend, returning a stream controlling this remote object.
  /// A transaction snapshot is taken by the backend when the object is opened with only read permissions.
  /// This means a transaction started after this method is called will not see any changes made.
  /// Note that this method, as well as operations on the stream must be wrapped inside a transaction.
  Future<NpgsqlLargeObjectStream> openRead(int oid) async {
    return _open(oid, _INV_READ);
  }

  /// Opens a large object on the backend, returning a stream controlling this remote object.
  /// Note that this method, as well as operations on the stream must be wrapped inside a transaction.
  Future<NpgsqlLargeObjectStream> openReadWrite(int oid) async {
    return _open(oid, _INV_READ | _INV_WRITE);
  }

  Future<NpgsqlLargeObjectStream> _open(int oid, int mode) async {
    final fd = await _executeFunction('lo_open', [oid, mode]);
    return NpgsqlLargeObjectStream(this, fd, (mode & _INV_WRITE) != 0);
  }

  /// Deletes a large object on the backend.
  Future<void> unlink(int oid) async {
    await _executeFunction('lo_unlink', [oid]);
  }

  /// Exports a large object stored in the database to a file on the backend.
  /// This requires superuser permissions.
  Future<void> exportRemote(int oid, String path) async {
    await _executeFunction('lo_export', [oid, path]);
  }

  /// Imports a large object into the database from a file on the backend.
  /// This requires superuser permissions.
  Future<int> importRemote(String path, [int preferredOid = 0]) async {
    return _executeFunction('lo_import', [path, preferredOid]);
  }

  // Internal methods for NpgsqlLargeObjectStream
  Future<Uint8List> loRead(int fd, int length) async {
    return _executeFunctionGetBytes('loread', [fd, length]);
  }

  Future<int> loWrite(int fd, Uint8List data) async {
    return _executeFunction('lowrite', [fd, data]);
  }

  Future<int> loSeek64(int fd, int offset, int origin) async {
    return _executeFunction('lo_lseek64', [fd, offset, origin]);
  }

  Future<int> loTell64(int fd) async {
    return _executeFunction('lo_tell64', [fd]);
  }

  Future<void> loTruncate64(int fd, int length) async {
    await _executeFunction('lo_truncate64', [fd, length]);
  }

  Future<void> loClose(int fd) async {
    await _executeFunction('lo_close', [fd]);
  }
}
