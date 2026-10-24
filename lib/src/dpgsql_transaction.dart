/// Represents a transaction transaction to be performed at a PostgreSQL database.
/// Porting DpgsqlTransaction.cs
import 'dpgsql_connection.dart';
import 'isolation_level.dart';
import 'postgres_exception.dart';
import 'protocol/backend_messages.dart';

class DpgsqlTransaction {
  DpgsqlTransaction(this._connection, this.isolationLevel,
      {void Function()? onCompleted})
      : _onCompleted = onCompleted;

  final DpgsqlConnection _connection;
  final IsolationLevel isolationLevel;
  final void Function()? _onCompleted;

  bool _isCompleted = false;

  DpgsqlConnection get connection => _connection;

  /// True after [commit] or [rollback].
  bool get isCompleted => _isCompleted;

  /// Commits the database transaction.
  ///
  /// Throws a [PostgresException] (SQLSTATE 25P02) when an error aborted the
  /// transaction and no ROLLBACK TO SAVEPOINT recovered from it: the server
  /// would answer the COMMIT with a ROLLBACK, not with an error, so the
  /// caller would take the rolled back writes for saved. It is rolled back.
  Future<void> commit() async {
    _checkCompleted();
    if (_connection.transactionStatus ==
        TransactionStatus.inFailedTransactionBlock) {
      await rollback();
      throw PostgresException(
        severity: 'ERROR',
        invariantSeverity: 'ERROR',
        sqlState: '25P02',
        messageText: 'The transaction was aborted by an earlier error and '
            'was rolled back instead of committed.',
      );
    }
    final reader = await _connection.executeReader('COMMIT');
    await reader.close();
    _complete();
  }

  /// Rolls back a transaction from a pending state.
  Future<void> rollback() async {
    _checkCompleted();
    final reader = await _connection.executeReader('ROLLBACK');
    await reader.close();
    _complete();
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
          'This DpgsqlTransaction has completed; it is no longer usable.');
    }
  }

  void _complete() {
    if (_isCompleted) {
      return;
    }
    _isCompleted = true;
    _onCompleted?.call();
  }
}
