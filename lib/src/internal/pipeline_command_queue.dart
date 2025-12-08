import 'dart:collection';
import 'pending_command.dart';

/// Manages a queue of pending commands in pipeline mode.
/// Porting concepts from Npgsql's pipeline management.
class PipelineCommandQueue {
  final Queue<PendingCommand> _queue = Queue<PendingCommand>();
  bool _inPipelineMode = false;

  /// Whether the connector is currently in pipeline mode.
  bool get inPipelineMode => _inPipelineMode;

  /// Whether the queue is empty.
  bool get isEmpty => _queue.isEmpty;

  /// Number of pending commands.
  int get length => _queue.length;

  /// Enter pipeline mode.
  void enterPipelineMode() {
    if (_inPipelineMode) {
      throw StateError('Already in pipeline mode');
    }
    _inPipelineMode = true;
  }

  /// Exit pipeline mode.
  /// This should only be called after all pending commands are processed.
  void exitPipelineMode() {
    if (!_inPipelineMode) {
      throw StateError('Not in pipeline mode');
    }
    if (_queue.isNotEmpty) {
      throw StateError('Cannot exit pipeline mode with pending commands');
    }
    _inPipelineMode = false;
  }

  /// Add a command to the queue.
  void enqueue(PendingCommand command) {
    if (!_inPipelineMode) {
      throw StateError('Cannot enqueue commands outside pipeline mode');
    }
    _queue.addLast(command);
  }

  /// Get the first pending command without removing it.
  PendingCommand? peek() {
    return _queue.isEmpty ? null : _queue.first;
  }

  /// Remove and return the first command.
  PendingCommand? dequeue() {
    return _queue.isEmpty ? null : _queue.removeFirst();
  }

  /// Remove completed/failed commands from the front of the queue.
  void removeCompleted() {
    while (_queue.isNotEmpty && _queue.first.isDone) {
      _queue.removeFirst();
    }
  }

  /// Clear all pending commands (typically on error/disconnect).
  void clear([Object? error, StackTrace? stackTrace]) {
    while (_queue.isNotEmpty) {
      final cmd = _queue.removeFirst();
      if (!cmd.isDone && error != null) {
        cmd.markFailed(error, stackTrace);
      }
    }
  }

  /// Fail all pending commands with the provided error without removing them yet.
  void failAll(Object error, [StackTrace? stackTrace]) {
    for (final cmd in _queue) {
      if (!cmd.isDone) {
        cmd.markFailed(error, stackTrace);
      }
    }
    removeCompleted();
  }

  /// Get all pending commands (for debugging).
  List<PendingCommand> getAll() => _queue.toList();

  @override
  String toString() {
    return 'PipelineCommandQueue(inPipeline: $_inPipelineMode, pending: ${_queue.length})';
  }
}
