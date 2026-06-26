import 'dart:async';
import 'dart:collection';

import '../dpgsql_batch_command.dart';
import '../pg_result_mode.dart';
import '../postgres_exception.dart';
import '../protocol/backend_messages.dart';

/// Enum representing the state of a command in the pipeline.
enum CommandState {
  /// Command has been sent but no response received yet.
  pending,

  /// Command is currently being processed (reading responses).
  processing,

  /// Command completed successfully.
  completed,

  /// Command failed with an error.
  failed,
}

/// Represents a command that has been sent to the server and is awaiting response(s).
/// Porting concepts from Dpgsql's pipeline management.
class PendingCommand {
  PendingCommand({
    required this.sql,
    required this.statementName,
    required this.expectedResponseCount,
    this.resultMode = PgResultMode.typed,
    Completer<void>? completer,
  }) : completer = completer ?? Completer<void>() {
    // Prevent unhandled asynchronous errors if nobody awaits [completed].
    // Consumers that do await will still observe the same error.
    this.completer.future.catchError((_) {});
  }

  /// The SQL text of the command (for debugging).
  final String sql;

  /// The prepared statement name (if any).
  final String? statementName;

  /// How many backend messages we expect for this command.
  /// For example:
  /// - Parse: 1 (ParseComplete)
  /// - Bind: 1 (BindComplete)
  /// - Describe: 1 (RowDescription or NoData)
  /// - Execute: variable (DataRow* + CommandComplete)
  /// - Sync: 1 (ReadyForQuery)
  final int expectedResponseCount;

  /// How result values for this command should be exposed to readers.
  final PgResultMode resultMode;

  /// Completer to signal when this command is done.
  final Completer<void> completer;
  final Queue<IBackendMessage> _messageQueue = Queue<IBackendMessage>();
  final StreamController<IBackendMessage> _messageController =
      StreamController<IBackendMessage>();

  Stream<IBackendMessage> get messageStream => _messageController.stream;

  /// Dequeues the next buffered message for this command, if any.
  IBackendMessage? takeMessage() {
    if (_messageQueue.isEmpty) {
      return null;
    }
    return _messageQueue.removeFirst();
  }

  /// Current state of this command.
  CommandState state = CommandState.pending;

  /// Number of responses received so far.
  int receivedResponseCount = 0;

  /// Error that occurred (if state == failed).
  Object? error;

  /// Stack trace of the error.
  StackTrace? stackTrace;

  /// Batch command associado (quando executado via DpgsqlBatch).
  DpgsqlBatchCommand? batchCommand;

  /// Command tag informado pelo servidor (e.g. "UPDATE 3").
  String? commandTag;

  /// Quantidade de linhas afetadas reportada pelo servidor.
  int recordsAffected = 0;

  /// Mark this command as having received a response.
  void recordResponse() {
    receivedResponseCount++;
  }

  /// Explicitly mark the command as completed.
  void markCompleted() {
    state = CommandState.completed;
    final batchCmd = batchCommand;
    if (batchCmd != null) {
      batchCmd.exception = null;
    }
    if (!completer.isCompleted) {
      completer.complete();
    }
    if (!_messageController.isClosed) {
      _messageController.close();
    }
  }

  /// Mark this command as failed.
  void markFailed(Object error, [StackTrace? stackTrace]) {
    state = CommandState.failed;
    this.error = error;
    this.stackTrace = stackTrace;
    final batchCmd = batchCommand;
    if (batchCmd != null && error is PostgresException) {
      batchCmd.exception = error;
    }
    if (!_messageController.isClosed) {
      if (_messageController.hasListener) {
        _messageController.addError(error, stackTrace);
      }
      _messageController.close();
    }
    if (!completer.isCompleted) {
      completer.completeError(error, stackTrace);
    }
  }

  /// Push a backend message related to this command to listeners.
  void addMessage(IBackendMessage message) {
    if (_messageController.isClosed) return;
    _messageQueue.addLast(message);
    _messageController.add(message);
  }

  Future<void> get completed => completer.future;

  /// Whether this command is done (completed or failed).
  bool get isDone =>
      state == CommandState.completed || state == CommandState.failed;

  @override
  String toString() {
    return 'PendingCommand(sql: ${sql.length > 50 ? sql.substring(0, 50) + '...' : sql}, '
        'state: $state, responses: $receivedResponseCount/$expectedResponseCount)';
  }
}
