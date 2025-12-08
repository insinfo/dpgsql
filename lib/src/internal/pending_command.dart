import 'dart:async';

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
/// Porting concepts from Npgsql's pipeline management.
class PendingCommand {
  PendingCommand({
    required this.sql,
    required this.statementName,
    required this.expectedResponseCount,
    this.completer,
  });

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

  /// Completer to signal when this command is done.
  final Completer? completer;

  /// Current state of this command.
  CommandState state = CommandState.pending;

  /// Number of responses received so far.
  int receivedResponseCount = 0;

  /// Error that occurred (if state == failed).
  Object? error;

  /// Stack trace of the error.
  StackTrace? stackTrace;

  /// Mark this command as having received a response.
  void recordResponse() {
    receivedResponseCount++;
    if (receivedResponseCount >= expectedResponseCount) {
      state = CommandState.completed;
      completer?.complete();
    }
  }

  /// Mark this command as failed.
  void markFailed(Object error, [StackTrace? stackTrace]) {
    state = CommandState.failed;
    this.error = error;
    this.stackTrace = stackTrace;
    completer?.completeError(error, stackTrace);
  }

  /// Whether this command is done (completed or failed).
  bool get isDone =>
      state == CommandState.completed || state == CommandState.failed;

  @override
  String toString() {
    return 'PendingCommand(sql: ${sql.length > 50 ? sql.substring(0, 50) + '...' : sql}, '
        'state: $state, responses: $receivedResponseCount/$expectedResponseCount)';
  }
}
