import 'dart:typed_data';
import 'dart:convert';
import 'oid.dart';

/// Base class for handling PostgreSQL types.
abstract class TypeHandler<T> {
  const TypeHandler();

  /// Reads a value of type T from the buffer.
  T read(Uint8List buffer);

  /// Writes a value of type T to a byte buffer.
  Uint8List write(T value);

  /// The default OID handled by this handler.
  int get oid;
}

class TextHandler extends TypeHandler<String> {
  const TextHandler();

  @override
  int get oid => Oid.text; // Also varchar, bpchar

  @override
  String read(Uint8List buffer) {
    return utf8.decode(buffer);
  }

  @override
  Uint8List write(String value) {
    return utf8.encode(value);
  }
}

class IntegerHandler extends TypeHandler<int> {
  const IntegerHandler();

  @override
  int get oid => Oid.int4;

  @override
  int read(Uint8List buffer) {
    final bd = ByteData.sublistView(buffer);
    if (buffer.length == 4) return bd.getInt32(0);
    if (buffer.length == 2) return bd.getInt16(0);
    if (buffer.length == 8) return bd.getInt64(0);
    throw FormatException('Invalid length for Integer: ${buffer.length}');
  }

  @override
  Uint8List write(int value) {
    final bd = ByteData(4);
    bd.setInt32(0, value);
    return bd.buffer.asUint8List();
  }
}

class BooleanHandler extends TypeHandler<bool> {
  const BooleanHandler();

  @override
  int get oid => Oid.bool;

  @override
  bool read(Uint8List buffer) {
    if (buffer.isEmpty) return false;
    return buffer[0] != 0;
  }

  @override
  Uint8List write(bool value) {
    return Uint8List.fromList([value ? 1 : 0]);
  }
}

class FloatHandler extends TypeHandler<double> {
  const FloatHandler();
  @override
  int get oid => Oid.float4;

  @override
  double read(Uint8List buffer) {
    final bd = ByteData.sublistView(buffer);
    if (buffer.length == 4) return bd.getFloat32(0);
    if (buffer.length == 8) return bd.getFloat64(0);
    throw FormatException('Invalid length for Float: ${buffer.length}');
  }

  @override
  Uint8List write(double value) {
    final bd = ByteData(4);
    bd.setFloat32(0, value);
    return bd.buffer.asUint8List();
  }
}

class DoubleHandler extends TypeHandler<double> {
  const DoubleHandler();
  @override
  int get oid => Oid.float8;

  @override
  double read(Uint8List buffer) {
    final bd = ByteData.sublistView(buffer);
    if (buffer.length == 8) return bd.getFloat64(0);
    if (buffer.length == 4) return bd.getFloat32(0);
    throw FormatException('Invalid length for Double: ${buffer.length}');
  }

  @override
  Uint8List write(double value) {
    final bd = ByteData(8);
    bd.setFloat64(0, value);
    return bd.buffer.asUint8List();
  }
}

class TimestampHandler extends TypeHandler<DateTime> {
  const TimestampHandler();
  @override
  int get oid => Oid.timestamp;

  static final DateTime _pgEpoch = DateTime.utc(2000, 1, 1);

  @override
  DateTime read(Uint8List buffer) {
    final bd = ByteData.sublistView(buffer);
    final micros = bd.getInt64(0);
    return _pgEpoch.add(Duration(microseconds: micros));
  }

  @override
  Uint8List write(DateTime value) {
    final diff = value.difference(_pgEpoch).inMicroseconds;
    final bd = ByteData(8);
    bd.setInt64(0, diff);
    return bd.buffer.asUint8List();
  }
}

class DateHandler extends TypeHandler<DateTime> {
  const DateHandler();
  @override
  int get oid => Oid.date;

  static final DateTime _pgEpoch = DateTime.utc(2000, 1, 1);

  @override
  DateTime read(Uint8List buffer) {
    final bd = ByteData.sublistView(buffer);
    final days = bd.getInt32(0);
    return _pgEpoch.add(Duration(days: days));
  }

  @override
  Uint8List write(DateTime value) {
    final diff = value.difference(_pgEpoch).inDays;
    final bd = ByteData(4);
    bd.setInt32(0, diff);
    return bd.buffer.asUint8List();
  }
}

class ByteaHandler extends TypeHandler<Uint8List> {
  const ByteaHandler();
  @override
  int get oid => Oid.bytea;

  @override
  Uint8List read(Uint8List buffer) {
    return buffer;
  }

  @override
  Uint8List write(Uint8List value) {
    return value;
  }
}

class ArrayHandler<E> extends TypeHandler<List<E>> {
  ArrayHandler(this.oid, this.elementHandler);

  @override
  final int oid;
  final TypeHandler<E> elementHandler;

  @override
  List<E> read(Uint8List buffer) {
    final bd = ByteData.sublistView(buffer);
    int offset = 0;

    // Header
    if (buffer.length < 12) return []; // Empty or invalid?
    final ndim = bd.getInt32(offset);
    offset += 4;
    bd.getInt32(offset); // flags (unused)
    offset += 4; // 0 or 1
    bd.getInt32(offset); // elementOid (unused)
    offset += 4;

    if (ndim == 0) return [];

    // Dimensions
    int count = 1;
    for (var i = 0; i < ndim; i++) {
      final dimSize = bd.getInt32(offset);
      offset += 4;
      bd.getInt32(offset); // lBound (unused)
      offset += 4; // usually 1
      count *= dimSize;
    }

    final result = <E>[];
    for (var i = 0; i < count; i++) {
      final len = bd.getInt32(offset);
      offset += 4;
      if (len == -1) {
        throw FormatException('Null elements in array not fully supported yet');
      } else {
        final elemBytes = buffer.sublist(offset, offset + len);
        offset += len;
        result.add(elementHandler.read(elemBytes));
      }
    }
    return result;
  }

  @override
  Uint8List write(List<E> value) {
    if (value.isEmpty) {
      // Empty array
      final out = ByteData(12);
      out.setInt32(0, 0); // ndim
      out.setInt32(4, 0); // flags
      out.setInt32(8, elementHandler.oid);
      return out.buffer.asUint8List();
    }

    final out = <int>[];
    // Header
    final header = ByteData(12);
    header.setInt32(0, 1); // ndim = 1 (Support 1D for now)
    header.setInt32(4, 0); // No nulls? Check values?
    header.setInt32(8, elementHandler.oid);
    out.addAll(header.buffer.asUint8List());

    // Dimension 1
    final dim = ByteData(8);
    dim.setInt32(0, value.length);
    dim.setInt32(4, 1); // lbound
    out.addAll(dim.buffer.asUint8List());

    // Values
    for (final item in value) {
      if (item == null) {
        // -1 length
        final nullLen = ByteData(4);
        nullLen.setInt32(0, -1);
        out.addAll(nullLen.buffer.asUint8List());
      } else {
        final bytes = elementHandler.write(item);
        final len = ByteData(4);
        len.setInt32(0, bytes.length);
        out.addAll(len.buffer.asUint8List());
        out.addAll(bytes);
      }
    }
    return Uint8List.fromList(out);
  }
}

class TypeHandlerRegistry {
  final Map<int, TypeHandler> _oidHandlers = {};

  TypeHandlerRegistry() {
    register(const TextHandler());
    register(const IntegerHandler());
    register(const BooleanHandler());
    register(const FloatHandler());
    register(const DoubleHandler());
    register(const TimestampHandler());
    register(const DateHandler());
    register(const ByteaHandler());

    // Arrays
    register(ArrayHandler<int>(Oid.int4Array, const IntegerHandler()));
    register(ArrayHandler<String>(Oid.textArray, const TextHandler()));
    register(ArrayHandler<bool>(Oid.boolArray, const BooleanHandler()));
    register(ArrayHandler<double>(Oid.float4Array, const FloatHandler()));
    register(ArrayHandler<double>(Oid.float8Array, const DoubleHandler()));

    // Mappings for aliases
    _oidHandlers[Oid.varchar] = const TextHandler();
    _oidHandlers[Oid.bpchar] = const TextHandler();
    _oidHandlers[Oid.unknown] = const TextHandler();
    _oidHandlers[Oid.int8] = const IntegerHandler();
    _oidHandlers[Oid.int2] = const IntegerHandler();
    _oidHandlers[Oid.timestamptz] = const TimestampHandler();
  }

  void register(TypeHandler handler) {
    _oidHandlers[handler.oid] = handler;
  }

  TypeHandler? resolve(int oid) {
    return _oidHandlers[oid];
  }

  TypeHandler? resolveByValue(dynamic value) {
    if (value is int) return _oidHandlers[Oid.int4];
    if (value is bool) return _oidHandlers[Oid.bool];
    if (value is String) return _oidHandlers[Oid.text];
    if (value is double) return _oidHandlers[Oid.float8];
    if (value is DateTime) return _oidHandlers[Oid.timestamp];
    if (value is Uint8List) return _oidHandlers[Oid.bytea];

    // Arrays
    if (value is List) {
      if (value.isEmpty) {
        // Fallback to text array? or unknown?
        return _oidHandlers[Oid.textArray];
      }
      final first = value.first;
      if (first is int) return _oidHandlers[Oid.int4Array];
      if (first is String) return _oidHandlers[Oid.textArray];
      if (first is bool) return _oidHandlers[Oid.boolArray];
      if (first is double) return _oidHandlers[Oid.float8Array];
    }

    return null;
  }

  TypeHandler<T>? resolveByDartType<T>() {
    if (T == int) return _oidHandlers[Oid.int4] as TypeHandler<T>?;
    if (T == String) return _oidHandlers[Oid.text] as TypeHandler<T>?;
    if (T == bool) return _oidHandlers[Oid.bool] as TypeHandler<T>?;
    if (T == double) return _oidHandlers[Oid.float8] as TypeHandler<T>?;
    if (T == DateTime) return _oidHandlers[Oid.timestamp] as TypeHandler<T>?;
    if (T == Uint8List) return _oidHandlers[Oid.bytea] as TypeHandler<T>?;
    return null;
  }
}
