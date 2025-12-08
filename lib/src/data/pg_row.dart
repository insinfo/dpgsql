import 'dart:typed_data';
import 'dart:convert';

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
  });

  final Uint8List buffer;
  final List<int> columnOffsets;
  final List<int> columnLengths;
  final List<String> columnNames;
  final List<int> columnTypes; // OIDs

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
    final bytes = this[index];
    if (bytes == null) return null;
    return encoding.decode(bytes);
  }

  /// Get column as int (binary format).
  int? getInt(int index) {
    final bytes = this[index];
    if (bytes == null) return null;

    final bd = ByteData.sublistView(bytes);
    switch (bytes.length) {
      case 2:
        return bd.getInt16(0);
      case 4:
        return bd.getInt32(0);
      case 8:
        return bd.getInt64(0);
      default:
        throw FormatException('Invalid int length: ${bytes.length}');
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

  /// Get column as bool.
  bool? getBool(int index) {
    final bytes = this[index];
    if (bytes == null) return null;
    return bytes.isNotEmpty && bytes[0] != 0;
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
  })  : _columnOffsets = List.filled(columnNames.length, 0),
        _columnLengths = List.filled(columnNames.length, 0),
        _bufferParts = [];

  final List<String> columnNames;
  final List<int> columnTypes;
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
    );
  }
}
