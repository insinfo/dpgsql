import 'dart:async';
import 'dart:convert';

import '../npgsql_batch_command.dart';
import '../npgsql_data_reader.dart';
import '../postgres_batch_exception.dart';
import '../postgres_exception.dart';
import '../protocol/backend_messages.dart';
import '../types/type_handler.dart';
import 'npgsql_connector.dart';
import 'pending_command.dart';

class NpgsqlDataReaderImpl implements NpgsqlDataReader {
  NpgsqlDataReaderImpl(this._connector,
      {List<PendingCommand>? pendingCommands,
      bool drainReadyOnClose = true,
      List<NpgsqlBatchCommand>? batchCommands})
      : _pendingCommands = pendingCommands,
        _drainReadyOnClose = drainReadyOnClose,
        _batchCommands = batchCommands;

  final NpgsqlConnector _connector;
  final TypeHandlerRegistry _typeRegistry = TypeHandlerRegistry();
  final List<PendingCommand>? _pendingCommands;
  final List<NpgsqlBatchCommand>? _batchCommands;
  final bool _drainReadyOnClose;

  RowDescriptionMessage? _rowDescription;
  DataRowMessage? _currentRow;
  int _recordsAffected = 0;
  bool _closed = false; // Public API closed state (user cannot read more)
  bool _drained = false; // Protocol state (ReadyForQuery received)
  bool get _isPipelineReader => _pendingCommands != null;
  int _pendingCommandIndex = -1;
  PendingCommand? _currentPendingCommand;

  Map<String, int>? _columnMap;

  Future<void> init() async {
    if (_isPipelineReader) {
      final pendingList = _pendingCommands!;
      if (pendingList.isEmpty) {
        _closed = true;
        _currentResultFinished = true;
        return;
      }
      _advancePendingCommand();
    }

    // Consumes messages until we get a RowDescription or CommandComplete (no rows)
    while (true) {
      final msg = await _getNextMessage();

      if (msg == null) {
        // Current command has already completed (no resultset)
        _closed = true;
        _currentResultFinished = true;
        return;
      }

      if (msg is ParseCompleteMessage || msg is BindCompleteMessage) {
        // Extended query flow
        continue;
      }

      if (msg is ParameterDescriptionMessage) {
        // Returned by Describe Statement
        continue;
      }

      if (msg is RowDescriptionMessage) {
        _rowDescription = msg;
        break;
      }
      if (msg is NoDataMessage) {
        _rowDescription = null;
        continue;
      }
      if (msg is DataRowMessage) {
        // Should not happen before RowDescription in simple query
        throw PostgresException(
            severity: 'ERROR',
            invariantSeverity: 'ERROR',
            sqlState: '08000',
            messageText: 'Unexpected DataRow before RowDescription');
      }
      if (msg is CommandCompleteMessage) {
        _handleCommandComplete(msg);
        _closed = true; // No data for user
        break;
      }
      if (msg is ReadyForQueryMessage) {
        _closed = true;
        _drained = true;
        break;
      }
      if (msg is ErrorResponseMessage) {
        _handleError(msg);
      }
      // Ignore others
    }
  }

  void _handleCommandComplete(CommandCompleteMessage msg) {
    final parts = msg.commandTag.split(' ');
    if (parts.isNotEmpty) {
      final last = parts.last;
      _recordsAffected = int.tryParse(last) ?? 0;
    }
  }

  void _handleError(ErrorResponseMessage msg) {
    final pendingError = _currentPendingCommand?.error;
    final baseException = pendingError is PostgresException
        ? pendingError
        : _createPostgresException(msg);

    final batchCommands = _batchCommands;
    if (batchCommands != null && batchCommands.isNotEmpty) {
      final failing = _currentPendingCommand?.batchCommand;
      var errorIndex = -1;
      if (failing != null) {
        errorIndex = batchCommands.indexOf(failing);
      }
      if (errorIndex == -1) {
        final pendingList = _pendingCommands;
        if (pendingList != null) {
          for (var i = 0; i < pendingList.length; i++) {
            final candidate = pendingList[i].batchCommand;
            if (candidate == null) continue;
            final idx = batchCommands.indexOf(candidate);
            if (idx != -1 && pendingList[i].state == CommandState.failed) {
              errorIndex = idx;
              break;
            }
          }
        }
      }

      throw PostgresBatchException(
        inner: baseException,
        commands: batchCommands,
        errorCommandIndex: errorIndex,
      );
    }

    throw baseException;
  }

  PostgresException _createPostgresException(ErrorResponseMessage msg) {
    final err = msg.error;
    return PostgresException(
        severity: err.severity ?? 'ERROR',
        invariantSeverity: err.invariantSeverity ?? err.severity ?? 'ERROR',
        sqlState: err.sqlState ?? '00000',
        messageText: err.messageText ?? 'Unknown Error',
        detail: err.detail,
        hint: err.hint,
        position: err.position ?? 0,
        internalPosition: err.internalPosition ?? 0,
        internalQuery: err.internalQuery,
        where: err.where,
        schemaName: err.schemaName,
        tableName: err.tableName,
        columnName: err.columnName,
        dataTypeName: err.dataTypeName,
        constraintName: err.constraintName,
        file: err.file,
        line: err.line,
        routine: err.routine);
  }

  void _advancePendingCommand() {
    final pendingList = _pendingCommands;
    if (pendingList == null) return;
    if (_pendingCommandIndex >= pendingList.length - 1) {
      _pendingCommandIndex = pendingList.length;
      _currentPendingCommand = null;
      return;
    }
    _pendingCommandIndex++;
    _currentPendingCommand = pendingList[_pendingCommandIndex];
  }

  Future<IBackendMessage?> _getNextMessage() async {
    if (_currentPendingCommand != null) {
      return _connector.readMessageForPending(_currentPendingCommand!);
    }
    return _connector.readMessage();
  }

  @override
  int get fieldCount => _rowDescription?.fields.length ?? 0;

  @override
  int get recordsAffected => _recordsAffected;

  @override
  Future<void> close() async {
    // Even if _closed is true, we might need to drain the protocol
    if (_drained) return;

    if (_isPipelineReader) {
      while (true) {
        if (_currentPendingCommand == null) {
          _advancePendingCommand();
          if (_currentPendingCommand == null) {
            break;
          }
        }

        while (true) {
          final msg = await _getNextMessage();
          if (msg == null) {
            break;
          }
          if (msg is CommandCompleteMessage) {
            _handleCommandComplete(msg);
            break;
          }
          if (msg is ErrorResponseMessage) {
            _handleError(msg);
          }
        }

        _currentPendingCommand = null;
      }
    }

    if (!_drainReadyOnClose) {
      _closed = true;
      return;
    }

    // Drain remaining messages until ReadyForQuery
    while (true) {
      final msg = await _connector.readMessage();
      if (msg is ReadyForQueryMessage) {
        break;
      }
      if (msg is ErrorResponseMessage) {
        // Ignore errors sending terminate/closing
      }
    }
    _closed = true;
    _drained = true;
  }

  @override
  int getOrdinal(String name) {
    if (_rowDescription == null) {
      throw StateError('No resultset available');
    }
    _columnMap ??= {
      for (var i = 0; i < _rowDescription!.fields.length; i++)
        _rowDescription!.fields[i].name: i
    };

    final index = _columnMap![name];
    if (index == null) {
      throw RangeError('Column "$name" not found');
    }
    return index;
  }

  @override
  dynamic operator [](index) {
    if (index is String) return this[getOrdinal(index)];
    if (index is! int) throw ArgumentError('Index must be int or String');

    if (_currentRow == null) {
      throw StateError('No current row. Call read() first.');
    }

    final colData = _currentRow!.columns[index];
    if (colData == null) return null; // DBNull

    final fieldDesc = _rowDescription!.fields[index];
    final oid = fieldDesc.oid;
    final isText = fieldDesc.format.code == 0;

    final handler = _typeRegistry.resolve(oid);
    if (handler != null) {
      return handler.read(colData, isText: isText);
    }

    // Fallback
    if (isText) return utf8.decode(colData);
    return colData;
  }

  @override
  dynamic getValue(int ordinal) => this[ordinal];

  @override
  Future<bool> nextResult() async {
    if (_drained) return false;

    // If we haven't finished the current result, drain it
    if (!_currentResultFinished) {
      while (await read()) {}
    }

    _currentResultFinished = false;
    _rowDescription = null;
    _currentRow = null;
    _columnMap = null;
    _recordsAffected = 0;
    _closed = false;

    if (_isPipelineReader) {
      _advancePendingCommand();
      if (_currentPendingCommand == null) {
        // No more pipelined commands; drain until ReadyForQuery
        while (true) {
          final msg = await _connector.readMessage();
          if (msg is ReadyForQueryMessage) {
            _drained = true;
            _closed = true;
            return false;
          }
          if (msg is CommandCompleteMessage) {
            _handleCommandComplete(msg);
            continue;
          }
          if (msg is ErrorResponseMessage) {
            _handleError(msg);
          }
        }
      }
    }

    while (true) {
      final msg = await _getNextMessage();

      if (msg == null) {
        _currentResultFinished = true;
        _closed = true;
        return false;
      }

      if (msg is ReadyForQueryMessage) {
        _drained = true;
        _closed = true;
        return false;
      }

      if (msg is RowDescriptionMessage) {
        _rowDescription = msg;
        return true;
      }

      if (msg is NoDataMessage) {
        // No rows for this result; wait for CommandComplete.
        continue;
      }

      if (msg is CommandCompleteMessage) {
        _handleCommandComplete(msg);
        // Result without rows
        _currentResultFinished = true; // No rows to read
        return true;
      }

      if (msg is ErrorResponseMessage) {
        _handleError(msg);
      }

      // Ignore BindComplete, ParseComplete, etc.
    }
  }

  bool _currentResultFinished = false;

  @override
  Future<bool> read() async {
    if (_closed || _currentResultFinished) return false;

    while (true) {
      final msg = await _getNextMessage();

      if (msg == null) {
        _currentRow = null;
        _currentResultFinished = true;
        _closed = true;
        return false;
      }

      if (msg is DataRowMessage) {
        _currentRow = msg;
        return true;
      }

      if (msg is RowDescriptionMessage) {
        // Should not happen inside a result set usually, unless interleaved?
        // Treat as start of new result? No, read() is for current result.
        // This might be a bug in state tracking if we get here.
        _rowDescription = msg;
        _columnMap = null;
        continue;
      }

      if (msg is NoDataMessage) {
        // No row data upcoming; rely on CommandComplete for termination.
        continue;
      }

      if (msg is CommandCompleteMessage) {
        _handleCommandComplete(msg);
        _currentRow = null;
        _currentResultFinished = true;
        return false;
      }

      if (msg is ReadyForQueryMessage) {
        _closed = true;
        _drained = true;
        _currentResultFinished = true;
        return false;
      }

      if (msg is ErrorResponseMessage) {
        _handleError(msg);
      }
    }
  }
}
