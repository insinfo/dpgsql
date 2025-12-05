/// Represents a transaction transaction to be performed at a PostgreSQL database.
/// Porting NpgsqlTransaction.cs
import 'npgsql_connection.dart';

class NpgsqlTransaction {
  NpgsqlTransaction(this._connection, this.isolationLevel);

  final NpgsqlConnection _connection;
  final String isolationLevel; // For now just string, TODO IsolationLevel enum

  bool _isCompleted = false;

  NpgsqlConnection get connection => _connection;

  /// Commits the database transaction.
  Future<void> commit() async {
    _checkCompleted();
    final reader = await _connection.executeReader('COMMIT');
    await reader.close();
    _isCompleted = true;
  }

  /// Rolls back a transaction from a pending state.
  Future<void> rollback() async {
    _checkCompleted();
    final reader = await _connection.executeReader('ROLLBACK');
    await reader.close();
    _isCompleted = true;
  }

  /// Creates a savepoint in the transaction.
  Future<void> save(String name) async {
    _checkCompleted();
    final reader = await _connection.executeReader('SAVEPOINT $name');
    await reader.close();
  }

  /// Rolls back a transaction from a pending state to the savepoint with the given name.
  Future<void> rollbackTo(String name) async {
    _checkCompleted();
    final reader =
        await _connection.executeReader('ROLLBACK TO SAVEPOINT $name');
    await reader.close();
  }

  /// Releases a savepoint with the given name.
  Future<void> release(String name) async {
    _checkCompleted();
    final reader = await _connection.executeReader('RELEASE SAVEPOINT $name');
    await reader.close();
  }

  void _checkCompleted() {
    if (_isCompleted) {
      throw StateError(
          'This NpgsqlTransaction has completed; it is no longer usable.');
    }
  }
}
