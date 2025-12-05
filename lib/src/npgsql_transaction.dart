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

  void _checkCompleted() {
    if (_isCompleted) {
      throw StateError(
          'This NpgsqlTransaction has completed; it is no longer usable.');
    }
  }
}
