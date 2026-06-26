import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../npgsql_batch_command.dart';
import '../npgsql_data_reader.dart';
import '../postgres_batch_exception.dart';
import '../postgres_exception.dart';
import '../protocol/backend_messages.dart';
import '../types/npgsql_types.dart';
import '../types/oid.dart';
import '../types/type_handler.dart';
import 'npgsql_connector.dart';
import 'pending_command.dart';
import 'timezone_helper.dart';

class NpgsqlDataReaderImpl implements NpgsqlDataReader {
  NpgsqlDataReaderImpl(this._connector,
      {List<PendingCommand>? pendingCommands,
      bool drainReadyOnClose = true,
      List<NpgsqlBatchCommand>? batchCommands})
      : _pendingCommands = pendingCommands,
        _drainReadyOnClose = drainReadyOnClose,
        _batchCommands = batchCommands;

  final NpgsqlConnector _connector;
  final List<PendingCommand>? _pendingCommands;
  final List<NpgsqlBatchCommand>? _batchCommands;
  final bool _drainReadyOnClose;

  RowDescriptionMessage? _rowDescription;
  DataRowMessage? _currentRow;
  List<Object?>? _currentRowValues;
  int _recordsAffected = 0;
  bool _closed = false; // Public API closed state (user cannot read more)
  bool _drained = false; // Protocol state (ReadyForQuery received)
  bool get _isPipelineReader => _pendingCommands != null;
  int _pendingCommandIndex = -1;
  PendingCommand? _currentPendingCommand;

  Map<String, int>? _columnMap;
  List<TypeHandler?>? _fieldHandlers;
  List<bool>? _fieldIsText;
  List<int>? _fieldOids;

  static final Object _notDecoded = Object();
  static final DateTime _timestampEpoch =
      TimezoneHelper.fixTimezoneTransition(DateTime(2000));

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

      if (msg is ParseCompleteMessage ||
          msg is BindCompleteMessage ||
          msg is CloseCompletedMessage) {
        // Extended query flow
        continue;
      }

      if (msg is ParameterDescriptionMessage) {
        // Returned by Describe Statement
        continue;
      }

      if (msg is RowDescriptionMessage) {
        _setRowDescription(msg);
        break;
      }
      if (msg is NoDataMessage) {
        _clearRowDescription();
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

  void _setRowDescription(RowDescriptionMessage msg) {
    _rowDescription = msg;
    _columnMap = null;

    final fields = msg.fields;
    final handlers = List<TypeHandler?>.filled(fields.length, null);
    final textFormats = List<bool>.filled(fields.length, false);
    final oids = List<int>.filled(fields.length, 0);
    final registry = _connector.typeRegistry;

    for (var i = 0; i < fields.length; i++) {
      final field = fields[i];
      oids[i] = field.oid;
      handlers[i] = registry.resolve(field.oid);
      textFormats[i] = field.format.code == 0;
    }

    _fieldHandlers = handlers;
    _fieldIsText = textFormats;
    _fieldOids = oids;
  }

  void _clearRowDescription() {
    _rowDescription = null;
    _columnMap = null;
    _fieldHandlers = null;
    _fieldIsText = null;
    _fieldOids = null;
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
    if (index is String) return _getValue(getOrdinal(index));
    if (index is! int) throw ArgumentError('Index must be int or String');
    return _getValue(index);
  }

  dynamic _getValue(int index) {
    if (_currentRow == null) {
      throw StateError('No current row. Call read() first.');
    }

    final cache = _currentRowValues ??=
        List<Object?>.filled(_currentRow!.columnCount, _notDecoded);
    final cached = cache[index];
    if (!identical(cached, _notDecoded)) {
      return cached;
    }

    final row = _currentRow!;
    final length = row.columnLengths[index];
    if (length == -1) {
      cache[index] = null;
      return null; // DBNull
    }
    final offset = row.columnOffsets[index];
    final payload = row.payload;

    final isText = _fieldIsText?[index] ?? true;
    final oid = _fieldOids?[index] ?? 0;

    final fastValue = _tryReadFast(payload, offset, length, oid, isText);
    if (!identical(fastValue, _notDecoded)) {
      cache[index] = fastValue;
      return fastValue;
    }

    final handler = _fieldHandlers?[index];
    final colData = row.getColumn(index)!;
    if (handler != null) {
      final value = handler.read(colData, isText: isText);
      cache[index] = value;
      return value;
    }

    // Fallback
    final value = isText ? utf8.decode(colData) : colData;
    cache[index] = value;
    return value;
  }

  Object? _tryReadFast(
    Uint8List payload,
    int offset,
    int length,
    int oid,
    bool isText,
  ) {
    if (isText) {
      switch (oid) {
        case Oid.text:
        case Oid.varchar:
        case Oid.bpchar:
        case Oid.unknown:
          return _decodeText(payload, offset, length);
        case Oid.int2:
        case Oid.int4:
        case Oid.int8:
          return int.parse(_decodeText(payload, offset, length));
        case Oid.bool:
          if (length == 1) {
            final b = payload[offset];
            return b == 116 || b == 49; // 't' or '1'
          }
          final value = _decodeText(payload, offset, length);
          return value == 'true' || value == '1';
        case Oid.float4:
        case Oid.float8:
          return double.parse(_decodeText(payload, offset, length));
      }
      return _notDecoded;
    }

    switch (oid) {
      case Oid.int2:
        if (length == 2) return _readInt16(payload, offset);
        return _notDecoded;
      case Oid.int4:
        if (length == 4) return _readInt32(payload, offset);
        return _notDecoded;
      case Oid.int8:
        if (length == 8) return _readInt64(payload, offset);
        return _notDecoded;
      case Oid.bool:
        return length > 0 && payload[offset] != 0;
      case Oid.text:
      case Oid.varchar:
      case Oid.bpchar:
      case Oid.unknown:
        return _decodeText(payload, offset, length);
      case Oid.float4:
        if (length == 4) {
          return ByteData.view(
                  payload.buffer, payload.offsetInBytes + offset, 4)
              .getFloat32(0);
        }
        return _notDecoded;
      case Oid.float8:
        if (length == 8) {
          return ByteData.view(
                  payload.buffer, payload.offsetInBytes + offset, 8)
              .getFloat64(0);
        }
        return _notDecoded;
      case Oid.timestamp:
      case Oid.timestamptz:
        if (length == 8) {
          return _timestampEpoch.add(Duration(
            microseconds: _readInt64(payload, offset),
          ));
        }
        return _notDecoded;
      case Oid.numeric:
        if (length >= 8) {
          return _readNumeric(payload, offset, length);
        }
        return _notDecoded;
    }

    return _notDecoded;
  }

  String _decodeText(Uint8List payload, int offset, int length) {
    if (identical(_connector.encoding, utf8)) {
      return utf8.decoder.convert(payload, offset, offset + length);
    }
    return _connector.encoding
        .decode(Uint8List.sublistView(payload, offset, offset + length));
  }

  int _readInt16(Uint8List payload, int offset) {
    final value = (payload[offset] << 8) | payload[offset + 1];
    return value.toSigned(16);
  }

  int _readInt32(Uint8List payload, int offset) {
    final value = (payload[offset] << 24) |
        (payload[offset + 1] << 16) |
        (payload[offset + 2] << 8) |
        payload[offset + 3];
    return value.toSigned(32);
  }

  int _readUint32(Uint8List payload, int offset) {
    return (payload[offset] << 24) |
        (payload[offset + 1] << 16) |
        (payload[offset + 2] << 8) |
        payload[offset + 3];
  }

  int _readInt64(Uint8List payload, int offset) {
    final high = _readInt32(payload, offset);
    final low = _readUint32(payload, offset + 4);
    return (high << 32) | low;
  }

  NpgsqlDecimal _readNumeric(Uint8List payload, int offset, int length) {
    final end = offset + length;
    if (offset + 8 > end) {
      throw FormatException('Invalid numeric length: $length');
    }

    final ndigits = _readInt16(payload, offset);
    offset += 2;
    final weight = _readInt16(payload, offset);
    offset += 2;
    final sign = _readInt16(payload, offset);
    offset += 2;
    final dscale = _readInt16(payload, offset);
    offset += 2;

    final digits = List<int>.filled(ndigits, 0);
    for (var i = 0; i < ndigits; i++) {
      if (offset + 2 > end) {
        throw FormatException('Invalid numeric digit length: $length');
      }
      digits[i] = _readInt16(payload, offset);
      offset += 2;
    }

    return NpgsqlDecimal(
      ndigits: ndigits,
      weight: weight,
      sign: sign,
      dscale: dscale,
      digits: digits,
    );
  }

  @override
  dynamic getValue(int ordinal) => _getValue(ordinal);

  @override
  Future<bool> nextResult() async {
    if (_drained) return false;

    // If we haven't finished the current result, drain it
    if (!_currentResultFinished) {
      while (await read()) {}
    }

    _currentResultFinished = false;
    _clearRowDescription();
    _currentRow = null;
    _currentRowValues = null;
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
        _setRowDescription(msg);
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
        _currentRowValues = null;
        _currentResultFinished = true;
        _closed = true;
        return false;
      }

      if (msg is DataRowMessage) {
        _currentRow = msg;
        _currentRowValues = null;
        return true;
      }

      if (msg is RowDescriptionMessage) {
        // Should not happen inside a result set usually, unless interleaved?
        // Treat as start of new result? No, read() is for current result.
        // This might be a bug in state tracking if we get here.
        _setRowDescription(msg);
        continue;
      }

      if (msg is NoDataMessage) {
        // No row data upcoming; rely on CommandComplete for termination.
        continue;
      }

      if (msg is CommandCompleteMessage) {
        _handleCommandComplete(msg);
        _currentRow = null;
        _currentRowValues = null;
        _currentResultFinished = true;
        return false;
      }

      if (msg is ReadyForQueryMessage) {
        _currentRow = null;
        _currentRowValues = null;
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
