import 'dart:typed_data';
import 'dart:convert';

import '../internal/timezone_helper.dart';
import '../timezone_settings.dart';
import '../types/oid.dart';

/// Efficient row representation with zero-copy buffer views.
///
/// Instead of creating a Map for each row, PgRow provides direct
/// access to column data in the underlying buffer, minimizing allocations.
class PgRow {
  PgRow({
    required this.buffer,
    required this.columnOffsets,
    required this.columnLengths,
    required this.columnNames,
    required this.columnTypes,
    this.timeZone = const TimeZoneSettings.utc(),
  });

  final Uint8List buffer;
  final List<int> columnOffsets;
  final List<int> columnLengths;
  final List<String> columnNames;
  final List<int> columnTypes; // OIDs
  final TimeZoneSettings timeZone;

  int get columnCount => columnNames.length;

  /// Get column value by index (zero-based).
  ///
  /// Returns null for NULL values.
  /// For other types, returns the raw bytes.
  Uint8List? operator [](int index) {
    if (index < 0 || index >= columnCount) {
      throw RangeError.index(index, this, 'index', null, columnCount);
    }

    final length = columnLengths[index];
    if (length == -1) return null; // NULL

    final offset = columnOffsets[index];
    return Uint8List.sublistView(buffer, offset, offset + length);
  }

  /// Get column value by name.
  Uint8List? getByName(String name) {
    final index = columnNames.indexOf(name);
    if (index == -1) {
      throw ArgumentError('Column "$name" not found');
    }
    return this[index];
  }

  /// Check if column is NULL.
  bool isNull(int index) => columnLengths[index] == -1;

  /// Get column as String (UTF-8 decoded).
  String? getString(int index, {Encoding encoding = utf8}) {
    RangeError.checkValidIndex(index, this, 'index', columnCount);
    final length = columnLengths[index];
    if (length == -1) return null;
    final offset = columnOffsets[index];
    final end = offset + length;
    if (identical(encoding, utf8)) {
      var asciiOnly = true;
      for (var i = offset; i < end; i++) {
        if (buffer[i] >= 0x80) {
          asciiOnly = false;
          break;
        }
      }
      if (asciiOnly) {
        return String.fromCharCodes(buffer, offset, end);
      }
      return utf8.decoder.convert(buffer, offset, end);
    }
    return encoding.decode(Uint8List.sublistView(buffer, offset, end));
  }

  /// Get column as int (binary format).
  int? getInt(int index) {
    RangeError.checkValidIndex(index, this, 'index', columnCount);
    final length = columnLengths[index];
    if (length == -1) return null;
    final offset = columnOffsets[index];
    switch (length) {
      case 2:
        final value = (buffer[offset] << 8) | buffer[offset + 1];
        return value.toSigned(16);
      case 4:
        final value = (buffer[offset] << 24) |
            (buffer[offset + 1] << 16) |
            (buffer[offset + 2] << 8) |
            buffer[offset + 3];
        return value.toSigned(32);
      case 8:
        final high = ((buffer[offset] << 24) |
                (buffer[offset + 1] << 16) |
                (buffer[offset + 2] << 8) |
                buffer[offset + 3])
            .toSigned(32);
        final low = (buffer[offset + 4] << 24) |
            (buffer[offset + 5] << 16) |
            (buffer[offset + 6] << 8) |
            buffer[offset + 7];
        return (high << 32) | low;
      default:
        throw FormatException('Invalid int length: $length');
    }
  }

  /// Get column as double (binary format).
  double? getDouble(int index) {
    final bytes = this[index];
    if (bytes == null) return null;

    final bd = ByteData.sublistView(bytes);
    switch (bytes.length) {
      case 4:
        return bd.getFloat32(0);
      case 8:
        return bd.getFloat64(0);
      default:
        throw FormatException('Invalid float length: ${bytes.length}');
    }
  }

  /// Get a PostgreSQL numeric column as double (binary format).
  double? getNumericDouble(int index) {
    RangeError.checkValidIndex(index, this, 'index', columnCount);
    var offset = columnOffsets[index];
    final length = columnLengths[index];
    if (length == -1) return null;
    final end = offset + length;
    if (offset + 8 > end) {
      throw FormatException('Invalid numeric length: $length');
    }

    final ndigits = _readInt16(offset);
    offset += 2;
    final weight = _readInt16(offset);
    offset += 2;
    final sign = _readInt16(offset);
    offset += 2;
    offset += 2;

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
      value = (value * 10000) + _readInt16(offset);
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

  /// Get a PostgreSQL timestamp/timestamptz column as DateTime (binary format).
  DateTime? getDateTime(int index) {
    RangeError.checkValidIndex(index, this, 'index', columnCount);
    final length = columnLengths[index];
    if (length == -1) return null;
    if (length != 8) {
      throw FormatException('Invalid timestamp length: $length');
    }
    final microseconds = _readInt64(columnOffsets[index]);
    return columnTypes[index] == Oid.timestamptz
        ? TimezoneHelper.decodeTimestampTz(microseconds, timeZone: timeZone)
        : TimezoneHelper.decodeTimestamp(microseconds, timeZone: timeZone);
  }

  /// Get column as bool.
  bool? getBool(int index) {
    final bytes = this[index];
    if (bytes == null) return null;
    return bytes.isNotEmpty && bytes[0] != 0;
  }

  int _readInt16(int offset) {
    final value = (buffer[offset] << 8) | buffer[offset + 1];
    return value.toSigned(16);
  }

  int _readUint32(int offset) {
    return (buffer[offset] << 24) |
        (buffer[offset + 1] << 16) |
        (buffer[offset + 2] << 8) |
        buffer[offset + 3];
  }

  int _readInt64(int offset) {
    final high = _readUint32(offset).toSigned(32);
    final low = _readUint32(offset + 4);
    return (high << 32) | low;
  }

  /// Convert row to Map (for compatibility).
  ///
  /// Note: This creates allocations - use direct access methods
  /// when possible for better performance.
  Map<String, dynamic> toMap({
    Encoding encoding = utf8,
    bool decodeStrings = true,
  }) {
    final map = <String, dynamic>{};
    for (var i = 0; i < columnCount; i++) {
      final name = columnNames[i];
      final bytes = this[i];

      if (bytes == null) {
        map[name] = null;
      } else if (decodeStrings) {
        map[name] = encoding.decode(bytes);
      } else {
        map[name] = bytes;
      }
    }
    return map;
  }

  /// Convert row to List.
  List<dynamic> toList({
    Encoding encoding = utf8,
    bool decodeStrings = true,
  }) {
    final list = <dynamic>[];
    for (var i = 0; i < columnCount; i++) {
      final bytes = this[i];

      if (bytes == null) {
        list.add(null);
      } else if (decodeStrings) {
        list.add(encoding.decode(bytes));
      } else {
        list.add(bytes);
      }
    }
    return list;
  }

  @override
  String toString() {
    final values = <String>[];
    for (var i = 0; i < columnCount; i++) {
      final name = columnNames[i];
      final value = isNull(i) ? 'NULL' : getString(i);
      values.add('$name: $value');
    }
    return 'PgRow{${values.join(', ')}}';
  }
}

/// Builder for efficient row construction.
class PgRowBuilder {
  PgRowBuilder({
    required this.columnNames,
    required this.columnTypes,
    this.timeZone = const TimeZoneSettings.utc(),
  })  : _columnOffsets = List.filled(columnNames.length, 0),
        _columnLengths = List.filled(columnNames.length, 0),
        _bufferParts = [];

  final List<String> columnNames;
  final List<int> columnTypes;
  final TimeZoneSettings timeZone;
  final List<int> _columnOffsets;
  final List<int> _columnLengths;
  final List<Uint8List> _bufferParts;
  int _currentOffset = 0;

  /// Add column value (or null).
  void addColumn(Uint8List? value, int columnIndex) {
    if (value == null) {
      _columnOffsets[columnIndex] = 0;
      _columnLengths[columnIndex] = -1; // NULL marker
    } else {
      _columnOffsets[columnIndex] = _currentOffset;
      _columnLengths[columnIndex] = value.length;
      _bufferParts.add(value);
      _currentOffset += value.length;
    }
  }

  /// Build the final PgRow.
  PgRow build() {
    // Concatenate all buffer parts
    final buffer = Uint8List(_currentOffset);
    var offset = 0;
    for (final part in _bufferParts) {
      buffer.setRange(offset, offset + part.length, part);
      offset += part.length;
    }

    return PgRow(
      buffer: buffer,
      columnOffsets: _columnOffsets,
      columnLengths: _columnLengths,
      columnNames: columnNames,
      columnTypes: columnTypes,
      timeZone: timeZone,
    );
  }
}
