import 'dart:typed_data';
import 'dart:convert';
import '../npgsql_db_type.dart';
import 'oid.dart';
import 'json_handler.dart';
import 'geometric_handlers.dart';
import 'range_handlers.dart';
import 'npgsql_types.dart';
import 'npgsql_geometric.dart';
import 'custom_type_handlers.dart';

/// Base class for handling PostgreSQL types.
abstract class TypeHandler<T> {
  const TypeHandler();

  /// Reads a value of type T from the buffer.
  T read(Uint8List buffer, {bool isText = false, Encoding encoding = utf8});

  /// Writes a value of type T to a byte buffer.
  Uint8List write(T value, {Encoding encoding = utf8});

  /// The default OID handled by this handler.
  int get oid;
}

class TextHandler extends TypeHandler<String> {
  const TextHandler();

  @override
  int get oid => Oid.text; // Also varchar, bpchar

  @override
  String read(Uint8List buffer,
      {bool isText = false, Encoding encoding = utf8}) {
    return encoding.decode(buffer);
  }

  @override
  Uint8List write(String value, {Encoding encoding = utf8}) {
    return Uint8List.fromList(encoding.encode(value));
  }
}

class IntegerHandler extends TypeHandler<int> {
  const IntegerHandler();

  @override
  int get oid => Oid.int4;

  @override
  int read(Uint8List buffer, {bool isText = false, Encoding encoding = utf8}) {
    if (isText) {
      final str = encoding.decode(buffer);
      return int.parse(str);
    }
    final bd = ByteData.sublistView(buffer);
    if (buffer.length == 4) return bd.getInt32(0);
    if (buffer.length == 2) return bd.getInt16(0);
    if (buffer.length == 8) return bd.getInt64(0);
    throw FormatException('Invalid length for Integer: ${buffer.length}');
  }

  @override
  Uint8List write(int value, {Encoding encoding = utf8}) {
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
  bool read(Uint8List buffer, {bool isText = false, Encoding encoding = utf8}) {
    if (isText) {
      final str = encoding.decode(buffer);
      return str == 't' || str == 'true' || str == '1';
    }
    if (buffer.isEmpty) return false;
    return buffer[0] != 0;
  }

  @override
  Uint8List write(bool value, {Encoding encoding = utf8}) {
    return Uint8List.fromList([value ? 1 : 0]);
  }
}

class FloatHandler extends TypeHandler<double> {
  const FloatHandler();
  @override
  int get oid => Oid.float4;

  @override
  double read(Uint8List buffer,
      {bool isText = false, Encoding encoding = utf8}) {
    if (isText) {
      return double.parse(encoding.decode(buffer));
    }
    final bd = ByteData.sublistView(buffer);
    if (buffer.length == 4) return bd.getFloat32(0);
    if (buffer.length == 8) return bd.getFloat64(0);
    throw FormatException('Invalid length for Float: ${buffer.length}');
  }

  @override
  Uint8List write(double value, {Encoding encoding = utf8}) {
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
  double read(Uint8List buffer,
      {bool isText = false, Encoding encoding = utf8}) {
    if (isText) {
      return double.parse(encoding.decode(buffer));
    }
    final bd = ByteData.sublistView(buffer);
    if (buffer.length == 8) return bd.getFloat64(0);
    if (buffer.length == 4) return bd.getFloat32(0);
    throw FormatException('Invalid length for Double: ${buffer.length}');
  }

  @override
  Uint8List write(double value, {Encoding encoding = utf8}) {
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
  DateTime read(Uint8List buffer,
      {bool isText = false, Encoding encoding = utf8}) {
    if (isText) {
      return DateTime.parse(encoding.decode(buffer)); // Basic ISO8601 support
    }
    final bd = ByteData.sublistView(buffer);
    final micros = bd.getInt64(0);
    return _pgEpoch.add(Duration(microseconds: micros));
  }

  @override
  Uint8List write(DateTime value, {Encoding encoding = utf8}) {
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
  DateTime read(Uint8List buffer,
      {bool isText = false, Encoding encoding = utf8}) {
    if (isText) {
      return DateTime.parse(encoding.decode(buffer));
    }
    final bd = ByteData.sublistView(buffer);
    final days = bd.getInt32(0);
    return _pgEpoch.add(Duration(days: days));
  }

  @override
  Uint8List write(DateTime value, {Encoding encoding = utf8}) {
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
  Uint8List read(Uint8List buffer,
      {bool isText = false, Encoding encoding = utf8}) {
    if (isText) {
      // TODO: Parse hex format \x...
      return buffer;
    }
    return buffer;
  }

  @override
  Uint8List write(Uint8List value, {Encoding encoding = utf8}) {
    return value;
  }
}

class ArrayHandler<E> extends TypeHandler<List<E>> {
  ArrayHandler(this.oid, this.elementHandler);

  @override
  final int oid;
  final TypeHandler elementHandler;

  @override
  List<E> read(Uint8List buffer,
      {bool isText = false, Encoding encoding = utf8}) {
    if (isText) {
      final text = encoding.decode(buffer);
      return _parseTextArray(text, encoding);
    }
    final bd = ByteData.sublistView(buffer);
    int offset = 0;

    if (buffer.length < 12) return <E>[];
    final ndim = bd.getInt32(offset);
    offset += 4;
    bd.getInt32(offset); // flags
    offset += 4;
    bd.getInt32(offset); // elementOid
    offset += 4;

    if (ndim == 0) return <E>[];

    final dims = <int>[];
    for (var i = 0; i < ndim; i++) {
      dims.add(bd.getInt32(offset));
      offset += 4;
      bd.getInt32(offset); // lBound
      offset += 4;
    }

    // Calculate total count
    int count = dims.fold(1, (a, b) => a * b);

    // Read all elements flattened
    final elements = <dynamic>[]; // Use dynamic to hold E or List<E>
    for (var i = 0; i < count; i++) {
      final len = bd.getInt32(offset);
      offset += 4;
      if (len == -1) {
        elements.add(null);
      } else {
        final elemBytes = buffer.sublist(offset, offset + len);
        offset += len;
        elements.add(elementHandler.read(elemBytes, encoding: encoding));
      }
    }

    // Reconstruct dimensions if ndim > 1
    if (ndim == 1) {
      return elements.cast<E>();
    } else {
      return _reconstructArray(elements, dims).cast<E>();
    }
  }

  List<E> _parseTextArray(String text, Encoding encoding) {
    if (text == '{}') return <E>[];
    final result = <dynamic>[];
    _parseArrayRecursive(text, 0, result, encoding);
    return result.cast<E>();
  }

  int _parseArrayRecursive(
      String text, int start, List<dynamic> currentList, Encoding encoding) {
    var i = start;
    if (i >= text.length || text[i] != '{') return i;
    i++; // Skip '{'

    while (i < text.length) {
      final char = text[i];
      if (char == '}') {
        return i + 1;
      } else if (char == '{') {
        final nestedList = <dynamic>[];
        currentList.add(nestedList);
        i = _parseArrayRecursive(text, i, nestedList, encoding);
      } else if (char == ',' ||
          char == ' ' ||
          char == '\t' ||
          char == '\n' ||
          char == '\r') {
        if (char == ',')
          i++;
        else
          i++;
      } else {
        // Element
        if (char == '"') {
          // Quoted
          final buffer = StringBuffer();
          i++;
          while (i < text.length) {
            if (text[i] == '"') {
              if (i + 1 < text.length && text[i + 1] == '"') {
                buffer.write('"');
                i += 2;
              } else {
                i++;
                break;
              }
            } else if (text[i] == '\\') {
              if (i + 1 < text.length) {
                buffer.write(text[i + 1]);
                i += 2;
              } else {
                buffer.write('\\');
                i++;
              }
            } else {
              buffer.write(text[i]);
              i++;
            }
          }
          final valStr = buffer.toString();
          currentList.add(elementHandler.read(
              Uint8List.fromList(encoding.encode(valStr)),
              isText: true,
              encoding: encoding));
        } else {
          // Unquoted
          final startElem = i;
          while (i < text.length && text[i] != ',' && text[i] != '}') {
            i++;
          }
          final valStr = text.substring(startElem, i);
          if (valStr.toUpperCase() == 'NULL') {
            currentList.add(null);
          } else {
            currentList.add(elementHandler.read(
                Uint8List.fromList(encoding.encode(valStr)),
                isText: true,
                encoding: encoding));
          }
        }
      }
    }
    return i;
  }

  List<dynamic> _reconstructArray(List<dynamic> flat, List<int> dims) {
    if (dims.length == 1) return flat;
    final currentDim = dims[0];
    final remainingDims = dims.sublist(1);
    final chunkSize = flat.length ~/ currentDim;

    final result = <dynamic>[];
    for (var i = 0; i < currentDim; i++) {
      final chunk = flat.sublist(i * chunkSize, (i + 1) * chunkSize);
      result.add(_reconstructArray(chunk, remainingDims));
    }
    return result;
  }

  @override
  Uint8List write(List<E> value, {Encoding encoding = utf8}) {
    final dims = <int>[];
    _calculateDims(value, dims);

    if (dims.isEmpty) {
      final out = ByteData(12);
      out.setInt32(0, 0);
      out.setInt32(4, 0);
      out.setInt32(8, elementHandler.oid);
      return out.buffer.asUint8List();
    }

    final out = <int>[];
    final header = ByteData(12);
    header.setInt32(0, dims.length);
    header.setInt32(4, 0); // hasNulls?
    header.setInt32(8, elementHandler.oid);
    out.addAll(header.buffer.asUint8List());

    for (final d in dims) {
      final dim = ByteData(8);
      dim.setInt32(0, d);
      dim.setInt32(4, 1); // lbound
      out.addAll(dim.buffer.asUint8List());
    }

    _writeRecursive(value, out, encoding);
    return Uint8List.fromList(out);
  }

  void _calculateDims(List list, List<int> dims) {
    dims.add(list.length);
    if (list.isNotEmpty && list.first is List) {
      _calculateDims(list.first as List, dims);
    }
  }

  void _writeRecursive(List list, List<int> out, Encoding encoding) {
    for (final item in list) {
      if (item is List) {
        _writeRecursive(item, out, encoding);
      } else {
        if (item == null) {
          final nullLen = ByteData(4);
          nullLen.setInt32(0, -1);
          out.addAll(nullLen.buffer.asUint8List());
        } else {
          final bytes = elementHandler.write(item, encoding: encoding);
          final len = ByteData(4);
          len.setInt32(0, bytes.length);
          out.addAll(len.buffer.asUint8List());
          out.addAll(bytes);
        }
      }
    }
  }
}

class TypeHandlerRegistry {
  final Map<int, TypeHandler> _oidHandlers = {};

  TypeHandlerRegistry({bool useNpgsqlTypes = false}) {
    register(const TextHandler());
    register(const IntegerHandler());
    register(const BooleanHandler());
    register(const FloatHandler());
    register(const DoubleHandler());
    register(const ByteaHandler());

    if (useNpgsqlTypes) {
      register(const NpgsqlDateHandler());
      register(const NpgsqlTimeHandler());
      register(const NpgsqlTimestampHandler());
    } else {
      register(const DateHandler());
      register(const TimestampHandler());
    }

    register(const NpgsqlIntervalHandler());
    register(const NpgsqlMoneyHandler());
    register(const NpgsqlDecimalHandler());

    register(const JsonHandler());
    register(const JsonbHandler());
    register(const PointHandler());
    register(const BoxHandler());
    register(const LSegHandler());
    register(const LineHandler());
    register(const PathHandler());
    register(const PolygonHandler());
    register(const CircleHandler());

    // Ranges
    register(RangeHandler<int>(Oid.int4range, const IntegerHandler()));
    register(RangeHandler<int>(Oid.int8range, const IntegerHandler()));
    register(RangeHandler<double>(Oid.numrange, const DoubleHandler()));
    register(RangeHandler<DateTime>(Oid.tsrange, const TimestampHandler()));
    register(RangeHandler<DateTime>(Oid.tstzrange, const TimestampHandler()));
    register(RangeHandler<DateTime>(Oid.daterange, const DateHandler()));

    // Arrays
    register(ArrayHandler<dynamic>(Oid.int4Array, const IntegerHandler()));
    register(ArrayHandler<dynamic>(Oid.textArray, const TextHandler()));
    register(ArrayHandler<dynamic>(Oid.boolArray, const BooleanHandler()));
    register(ArrayHandler<dynamic>(Oid.float4Array, const FloatHandler()));
    register(ArrayHandler<dynamic>(Oid.float8Array, const DoubleHandler()));

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

    // Npgsql Types
    if (value is NpgsqlDate) return _oidHandlers[Oid.date];
    if (value is NpgsqlTime) return _oidHandlers[Oid.time];
    if (value is NpgsqlTimestamp) return _oidHandlers[Oid.timestamp];
    if (value is NpgsqlInterval) return _oidHandlers[Oid.interval];
    if (value is NpgsqlMoney) return _oidHandlers[Oid.money];
    if (value is NpgsqlDecimal) return _oidHandlers[Oid.numeric];

    // Geometric Types
    if (value is NpgsqlPoint) return _oidHandlers[Oid.point];
    if (value is NpgsqlBox) return _oidHandlers[Oid.box];
    if (value is NpgsqlLSeg) return _oidHandlers[Oid.lseg];
    if (value is NpgsqlLine) return _oidHandlers[Oid.line];
    if (value is NpgsqlPath) return _oidHandlers[Oid.path];
    if (value is NpgsqlPolygon) return _oidHandlers[Oid.polygon];
    if (value is NpgsqlCircle) return _oidHandlers[Oid.circle];

    // Arrays
    if (value is List) {
      if (value.isEmpty) {
        return _oidHandlers[Oid.textArray];
      }
      var first = value.first;
      while (first is List && first.isNotEmpty) {
        first = first.first;
      }

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

    if (T == NpgsqlDate) return _oidHandlers[Oid.date] as TypeHandler<T>?;
    if (T == NpgsqlTime) return _oidHandlers[Oid.time] as TypeHandler<T>?;
    if (T == NpgsqlTimestamp)
      return _oidHandlers[Oid.timestamp] as TypeHandler<T>?;
    if (T == NpgsqlInterval)
      return _oidHandlers[Oid.interval] as TypeHandler<T>?;
    if (T == NpgsqlMoney) return _oidHandlers[Oid.money] as TypeHandler<T>?;
    if (T == NpgsqlDecimal) return _oidHandlers[Oid.numeric] as TypeHandler<T>?;

    if (T == NpgsqlPoint) return _oidHandlers[Oid.point] as TypeHandler<T>?;
    if (T == NpgsqlBox) return _oidHandlers[Oid.box] as TypeHandler<T>?;
    if (T == NpgsqlLSeg) return _oidHandlers[Oid.lseg] as TypeHandler<T>?;
    if (T == NpgsqlLine) return _oidHandlers[Oid.line] as TypeHandler<T>?;
    if (T == NpgsqlPath) return _oidHandlers[Oid.path] as TypeHandler<T>?;
    if (T == NpgsqlPolygon) return _oidHandlers[Oid.polygon] as TypeHandler<T>?;
    if (T == NpgsqlCircle) return _oidHandlers[Oid.circle] as TypeHandler<T>?;

    if (T == List<int>)
      return ArrayHandler<int>(Oid.int4Array, const IntegerHandler())
          as TypeHandler<T>?;
    if (T == List<String>)
      return ArrayHandler<String>(Oid.textArray, const TextHandler())
          as TypeHandler<T>?;
    if (T == List<bool>)
      return ArrayHandler<bool>(Oid.boolArray, const BooleanHandler())
          as TypeHandler<T>?;
    if (T == List<double>)
      return ArrayHandler<double>(Oid.float8Array, const DoubleHandler())
          as TypeHandler<T>?;

    if (T == List<int?>)
      return ArrayHandler<int?>(Oid.int4Array, const IntegerHandler())
          as TypeHandler<T>?;
    if (T == List<String?>)
      return ArrayHandler<String?>(Oid.textArray, const TextHandler())
          as TypeHandler<T>?;
    if (T == List<bool?>)
      return ArrayHandler<bool?>(Oid.boolArray, const BooleanHandler())
          as TypeHandler<T>?;
    if (T == List<double?>)
      return ArrayHandler<double?>(Oid.float8Array, const DoubleHandler())
          as TypeHandler<T>?;

    return null;
  }

  TypeHandler? resolveByNpgsqlDbType(NpgsqlDbType dbType) {
    switch (dbType) {
      case NpgsqlDbType.bigint:
        return _oidHandlers[Oid.int8];
      case NpgsqlDbType.boolean:
        return _oidHandlers[Oid.bool];
      case NpgsqlDbType.box:
        return _oidHandlers[Oid.box];
      case NpgsqlDbType.bytea:
        return _oidHandlers[Oid.bytea];
      case NpgsqlDbType.circle:
        return _oidHandlers[Oid.circle];
      case NpgsqlDbType.char:
        return _oidHandlers[Oid.bpchar];
      case NpgsqlDbType.date:
        return _oidHandlers[Oid.date];
      case NpgsqlDbType.double:
        return _oidHandlers[Oid.float8];
      case NpgsqlDbType.integer:
        return _oidHandlers[Oid.int4];
      case NpgsqlDbType.json:
        return _oidHandlers[Oid.json];
      case NpgsqlDbType.jsonb:
        return _oidHandlers[Oid.jsonb];
      case NpgsqlDbType.line:
        return _oidHandlers[Oid.line];
      case NpgsqlDbType.lSeg:
        return _oidHandlers[Oid.lseg];
      case NpgsqlDbType.money:
        return _oidHandlers[Oid.money];
      case NpgsqlDbType.numeric:
        return _oidHandlers[Oid.numeric];
      case NpgsqlDbType.path:
        return _oidHandlers[Oid.path];
      case NpgsqlDbType.point:
        return _oidHandlers[Oid.point];
      case NpgsqlDbType.polygon:
        return _oidHandlers[Oid.polygon];
      case NpgsqlDbType.real:
        return _oidHandlers[Oid.float4];
      case NpgsqlDbType.smallint:
        return _oidHandlers[Oid.int2];
      case NpgsqlDbType.text:
        return _oidHandlers[Oid.text];
      case NpgsqlDbType.time:
        return _oidHandlers[Oid.time];
      case NpgsqlDbType.timestamp:
        return _oidHandlers[Oid.timestamp];
      case NpgsqlDbType.timestampTz:
        return _oidHandlers[Oid.timestamptz];
      case NpgsqlDbType.uuid:
        return _oidHandlers[Oid.uuid];
      case NpgsqlDbType.varbit:
        return _oidHandlers[Oid.varbit];
      case NpgsqlDbType.varchar:
        return _oidHandlers[Oid.varchar];
      case NpgsqlDbType.xml:
        return _oidHandlers[Oid.xml];
      case NpgsqlDbType.unknown:
        return _oidHandlers[Oid.unknown];
      case NpgsqlDbType.integerRange:
        return resolve(Oid.int4range);
      case NpgsqlDbType.bigIntRange:
        return resolve(Oid.int8range);
      case NpgsqlDbType.numRange:
        return resolve(Oid.numrange);
      case NpgsqlDbType.tsRange:
        return resolve(Oid.tsrange);
      case NpgsqlDbType.tsTzRange:
        return resolve(Oid.tstzrange);
      case NpgsqlDbType.dateRange:
        return resolve(Oid.daterange);
    }
  }
}
