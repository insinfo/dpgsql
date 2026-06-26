import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../dpgsql_batch_command.dart';
import '../dpgsql_data_reader.dart';
import '../pg_result_mode.dart';
import '../postgres_batch_exception.dart';
import '../postgres_exception.dart';
import '../protocol/backend_messages.dart';
import '../types/oid.dart';
import '../types/type_handler.dart';
import 'dpgsql_connector.dart';
import 'pending_command.dart';
import 'timezone_helper.dart';

class DpgsqlDataReaderImpl implements DpgsqlDataReader {
  DpgsqlDataReaderImpl(this._connector,
      {List<PendingCommand>? pendingCommands,
      bool drainReadyOnClose = true,
      List<DpgsqlBatchCommand>? batchCommands,
      PgResultMode resultMode = PgResultMode.typed})
      : _pendingCommands = pendingCommands,
        _drainReadyOnClose = drainReadyOnClose,
        _batchCommands = batchCommands,
        _resultMode = resultMode;

  final DpgsqlConnector _connector;
  final List<PendingCommand>? _pendingCommands;
  final List<DpgsqlBatchCommand>? _batchCommands;
  final bool _drainReadyOnClose;
  final PgResultMode _resultMode;

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
        final exception = _createExceptionForError(msg);
        if (!_isPipelineReader) {
          await _drainUntilReadyForQuery();
        }
        throw exception;
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

  Never _handleError(ErrorResponseMessage msg) {
    throw _createExceptionForError(msg);
  }

  PostgresException _createExceptionForError(ErrorResponseMessage msg) {
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

      return PostgresBatchException(
        inner: baseException,
        commands: batchCommands,
        errorCommandIndex: errorIndex,
      );
    }

    return baseException;
  }

  Future<void> _drainUntilReadyForQuery() async {
    if (_drained) {
      return;
    }

    while (true) {
      final msg = await _connector.readMessage();
      if (msg is ReadyForQueryMessage) {
        _closed = true;
        _drained = true;
        return;
      }
    }
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

    if (_resultMode == PgResultMode.rawText) {
      final value = _decodeText(payload, offset, length);
      cache[index] = value;
      return value;
    }

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

  int _checkedColumnLength(int index) {
    final row = _currentRow;
    if (row == null) {
      throw StateError('No current row. Call read() first.');
    }
    RangeError.checkValidIndex(index, row, 'ordinal', row.columnCount);
    final length = row.columnLengths[index];
    if (length == -1) {
      throw StateError('Column $index is NULL');
    }
    return length;
  }

  @override
  bool isDBNull(int ordinal) {
    final row = _currentRow;
    if (row == null) {
      throw StateError('No current row. Call read() first.');
    }
    RangeError.checkValidIndex(ordinal, row, 'ordinal', row.columnCount);
    return row.columnLengths[ordinal] == -1;
  }

  @override
  int getInt(int ordinal) {
    final length = _checkedColumnLength(ordinal);
    final row = _currentRow!;
    final offset = row.columnOffsets[ordinal];
    final payload = row.payload;
    final oid = _fieldOids?[ordinal] ?? 0;
    final isText = _fieldIsText?[ordinal] ?? true;

    if (isText) {
      return int.parse(_decodeText(payload, offset, length));
    }
    switch (oid) {
      case Oid.int2:
        if (length == 2) return _readInt16(payload, offset);
        break;
      case Oid.int4:
        if (length == 4) return _readInt32(payload, offset);
        break;
      case Oid.int8:
        if (length == 8) return _readInt64(payload, offset);
        break;
    }

    final value = _getValue(ordinal);
    if (value is int) return value;
    throw StateError('Column $ordinal is not an int');
  }

  @override
  String getString(int ordinal) {
    final length = _checkedColumnLength(ordinal);
    final row = _currentRow!;
    final offset = row.columnOffsets[ordinal];
    final payload = row.payload;
    final oid = _fieldOids?[ordinal] ?? 0;
    final isText = _fieldIsText?[ordinal] ?? true;

    if (isText ||
        oid == Oid.text ||
        oid == Oid.varchar ||
        oid == Oid.bpchar ||
        oid == Oid.unknown) {
      return _decodeText(payload, offset, length);
    }

    final value = _getValue(ordinal);
    if (value is String) return value;
    return value.toString();
  }

  @override
  double getDouble(int ordinal) {
    final length = _checkedColumnLength(ordinal);
    final row = _currentRow!;
    final offset = row.columnOffsets[ordinal];
    final payload = row.payload;
    final oid = _fieldOids?[ordinal] ?? 0;
    final isText = _fieldIsText?[ordinal] ?? true;

    if (isText) {
      return double.parse(_decodeText(payload, offset, length));
    }
    if (oid == Oid.float4 && length == 4) {
      return ByteData.view(payload.buffer, payload.offsetInBytes + offset, 4)
          .getFloat32(0);
    }
    if (oid == Oid.float8 && length == 8) {
      return ByteData.view(payload.buffer, payload.offsetInBytes + offset, 8)
          .getFloat64(0);
    }
    if (oid == Oid.numeric && length >= 8) {
      return _readNumericDouble(payload, offset, length);
    }

    final value = _getValue(ordinal);
    if (value is double) return value;
    if (value is int) return value.toDouble();
    throw StateError('Column $ordinal is not a double');
  }

  @override
  bool getBool(int ordinal) {
    final length = _checkedColumnLength(ordinal);
    final row = _currentRow!;
    final offset = row.columnOffsets[ordinal];
    final payload = row.payload;
    final isText = _fieldIsText?[ordinal] ?? true;

    if (!isText) {
      return length > 0 && payload[offset] != 0;
    }
    if (length == 1) {
      final b = payload[offset];
      return b == 116 || b == 49; // 't' or '1'
    }
    final value = _decodeText(payload, offset, length);
    return value == 'true' || value == '1';
  }

  @override
  DateTime getDateTime(int ordinal) {
    final length = _checkedColumnLength(ordinal);
    final row = _currentRow!;
    final offset = row.columnOffsets[ordinal];
    final payload = row.payload;
    final oid = _fieldOids?[ordinal] ?? 0;
    final isText = _fieldIsText?[ordinal] ?? true;

    if (isText) {
      final value = _decodeText(payload, offset, length);
      if (oid == Oid.timestamptz) {
        final decoded = TimezoneHelper.decodeTimestampTzText(
          value,
          timeZone: _connector.timeZone,
        );
        if (decoded == null) {
          throw StateError('Column $ordinal is infinity');
        }
        return decoded;
      }
      if (oid == Oid.date) {
        final decoded = TimezoneHelper.decodeDateText(
          value,
          timeZone: _connector.timeZone,
        );
        if (decoded == null) {
          throw StateError('Column $ordinal is infinity');
        }
        return decoded;
      }
      final decoded = TimezoneHelper.decodeTimestampText(
        value,
        timeZone: _connector.timeZone,
      );
      if (decoded == null) {
        throw StateError('Column $ordinal is infinity');
      }
      return decoded;
    }
    if (oid == Oid.timestamp && length == 8) {
      final decoded = TimezoneHelper.decodeTimestamp(
        _readInt64(payload, offset),
        timeZone: _connector.timeZone,
      );
      if (decoded == null) {
        throw StateError('Column $ordinal is infinity');
      }
      return decoded;
    }
    if (oid == Oid.timestamptz && length == 8) {
      final decoded = TimezoneHelper.decodeTimestampTz(
        _readInt64(payload, offset),
        timeZone: _connector.timeZone,
      );
      if (decoded == null) {
        throw StateError('Column $ordinal is infinity');
      }
      return decoded;
    }

    final value = _getValue(ordinal);
    if (value is DateTime) return value;
    throw StateError('Column $ordinal is not a DateTime');
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
        case Oid.date:
          return TimezoneHelper.decodeDateText(
            _decodeText(payload, offset, length),
            timeZone: _connector.timeZone,
          );
        case Oid.timestamp:
          return TimezoneHelper.decodeTimestampText(
            _decodeText(payload, offset, length),
            timeZone: _connector.timeZone,
          );
        case Oid.timestamptz:
          return TimezoneHelper.decodeTimestampTzText(
            _decodeText(payload, offset, length),
            timeZone: _connector.timeZone,
          );
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
        if (length == 8) {
          return TimezoneHelper.decodeTimestamp(
            _readInt64(payload, offset),
            timeZone: _connector.timeZone,
          );
        }
        return _notDecoded;
      case Oid.timestamptz:
        if (length == 8) {
          return TimezoneHelper.decodeTimestampTz(
            _readInt64(payload, offset),
            timeZone: _connector.timeZone,
          );
        }
        return _notDecoded;
      case Oid.date:
        if (length == 4) {
          return TimezoneHelper.decodeDate(
            _readInt32(payload, offset),
            timeZone: _connector.timeZone,
          );
        }
        return _notDecoded;
    }

    return _notDecoded;
  }

  double _readNumericDouble(Uint8List payload, int offset, int length) {
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
    offset += 2; // dscale

    if (sign == 0xC000) {
      return double.nan;
    }
    if (ndigits == 0) {
      return sign == 0x4000 ? -0.0 : 0.0;
    }

    var value = 0.0;
    for (var i = 0; i < ndigits; i++) {
      if (offset + 2 > end) {
        throw FormatException('Invalid numeric digit length: $length');
      }
      value = (value * 10000) + _readInt16(payload, offset);
      offset += 2;
    }

    var scaleGroups = ndigits - weight - 1;
    while (scaleGroups > 0) {
      value /= 10000;
      scaleGroups--;
    }
    while (scaleGroups < 0) {
      value *= 10000;
      scaleGroups++;
    }

    return sign == 0x4000 ? -value : value;
  }

  String _decodeText(Uint8List payload, int offset, int length) {
    if (identical(_connector.encoding, utf8)) {
      final end = offset + length;
      var asciiOnly = true;
      for (var i = offset; i < end; i++) {
        if (payload[i] >= 0x80) {
          asciiOnly = false;
          break;
        }
      }
      if (asciiOnly) {
        return String.fromCharCodes(payload, offset, end);
      }
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

  @override
  dynamic getValue(int ordinal) => _getValue(ordinal);

  @override
  Map<String, dynamic> toMap() {
    if (_currentRow == null) {
      throw StateError('No current row. Call read() first.');
    }
    final fields = _rowDescription?.fields;
    if (fields == null) {
      throw StateError('No resultset available');
    }

    final map = <String, dynamic>{};
    for (var i = 0; i < fields.length; i++) {
      map[fields[i].name] = _getValue(i);
    }
    return map;
  }

  Future<List<List<Object?>>> readAllRows() async {
    final rows = <List<Object?>>[];
    if (_closed || _currentResultFinished) {
      return rows;
    }

    while (true) {
      final msg = await _getNextMessage();

      if (msg == null) {
        _currentRow = null;
        _currentRowValues = null;
        _currentResultFinished = true;
        _closed = true;
        return rows;
      }

      if (msg is DataRowMessage) {
        rows.add(_decodeRowValues(msg));
        continue;
      }

      if (msg is RowDescriptionMessage) {
        _setRowDescription(msg);
        continue;
      }

      if (msg is NoDataMessage ||
          msg is ParseCompleteMessage ||
          msg is BindCompleteMessage ||
          msg is CloseCompletedMessage ||
          msg is ParameterDescriptionMessage) {
        continue;
      }

      if (msg is CommandCompleteMessage) {
        _handleCommandComplete(msg);
        _currentResultFinished = true;
        continue;
      }

      if (msg is ReadyForQueryMessage) {
        _currentRow = null;
        _currentRowValues = null;
        _closed = true;
        _drained = true;
        _currentResultFinished = true;
        return rows;
      }

      if (msg is ErrorResponseMessage) {
        _handleError(msg);
      }
    }
  }

  List<Object?> _decodeRowValues(DataRowMessage row) {
    final values = List<Object?>.filled(row.columnCount, null);
    for (var i = 0; i < row.columnCount; i++) {
      values[i] = _decodeRowValue(row, i);
    }

    return values;
  }

  @override
  Future<List<Map<String, dynamic>>> readAllMaps() async {
    final rows = <Map<String, dynamic>>[];
    if (_closed || _currentResultFinished) {
      return rows;
    }

    while (true) {
      final msg = await _getNextMessage();

      if (msg == null) {
        _currentRow = null;
        _currentRowValues = null;
        _currentResultFinished = true;
        _closed = true;
        return rows;
      }

      if (msg is DataRowMessage) {
        rows.add(_decodeRowMap(msg));
        continue;
      }

      if (msg is RowDescriptionMessage) {
        _setRowDescription(msg);
        continue;
      }

      if (msg is NoDataMessage ||
          msg is ParseCompleteMessage ||
          msg is BindCompleteMessage ||
          msg is CloseCompletedMessage ||
          msg is ParameterDescriptionMessage) {
        continue;
      }

      if (msg is CommandCompleteMessage) {
        _handleCommandComplete(msg);
        _currentResultFinished = true;
        continue;
      }

      if (msg is ReadyForQueryMessage) {
        _currentRow = null;
        _currentRowValues = null;
        _closed = true;
        _drained = true;
        _currentResultFinished = true;
        return rows;
      }

      if (msg is ErrorResponseMessage) {
        _handleError(msg);
      }
    }
  }

  Map<String, dynamic> _decodeRowMap(DataRowMessage row) {
    final fields = _rowDescription?.fields;
    if (fields == null) {
      throw StateError('No resultset available');
    }

    final map = <String, dynamic>{};
    for (var i = 0; i < fields.length; i++) {
      map[fields[i].name] = _decodeRowValue(row, i);
    }
    return map;
  }

  Object? _decodeRowValue(DataRowMessage row, int index) {
    final length = row.columnLengths[index];
    if (length == -1) {
      return null;
    }

    final offset = row.columnOffsets[index];
    final payload = row.payload;

    if (_resultMode == PgResultMode.rawText) {
      return _decodeText(payload, offset, length);
    }

    final oid = _fieldOids?[index] ?? 0;
    final isText = _fieldIsText?[index] ?? true;

    final fastValue = _tryReadFast(payload, offset, length, oid, isText);
    if (!identical(fastValue, _notDecoded)) {
      return fastValue;
    }

    final handler = _fieldHandlers?[index];
    if (!isText && oid == Oid.numeric && handler is TypeHandler<double>) {
      return _readNumericDouble(payload, offset, length);
    }

    final colData = Uint8List.sublistView(payload, offset, offset + length);
    return handler?.read(colData, isText: isText) ??
        (isText ? utf8.decode(colData) : colData);
  }

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
        final cache = _currentRowValues;
        if (cache != null) {
          if (cache.length == msg.columnCount) {
            cache.fillRange(0, cache.length, _notDecoded);
          } else {
            _currentRowValues = null;
          }
        }
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
