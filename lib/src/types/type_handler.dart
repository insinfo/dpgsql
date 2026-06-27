import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import '../dpgsql_db_type.dart';
import '../internal/timezone_helper.dart';
import '../timezone_settings.dart';
import 'oid.dart';
import 'json_handler.dart';
import 'geometric_handlers.dart';
import 'range_handlers.dart';
import 'dpgsql_types.dart';
import 'dpgsql_geometric.dart';
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
  const TimestampHandler({
    this.timeZone = const TimeZoneSettings.utc(),
    this.timestampTz = false,
  });

  final TimeZoneSettings timeZone;
  final bool timestampTz;

  @override
  int get oid => timestampTz ? Oid.timestamptz : Oid.timestamp;

  @override
  DateTime read(Uint8List buffer,
      {bool isText = false, Encoding encoding = utf8}) {
    DateTime? value;
    if (isText) {
      final text = encoding.decode(buffer);
      value = timestampTz
          ? TimezoneHelper.decodeTimestampTzText(text, timeZone: timeZone)
          : TimezoneHelper.decodeTimestampText(text, timeZone: timeZone);
      if (value == null) {
        throw ArgumentError('Timestamp value is infinity');
      }
      return value;
    }
    final bd = ByteData.sublistView(buffer);
    final micros = bd.getInt64(0);

    value = timestampTz
        ? TimezoneHelper.decodeTimestampTz(micros, timeZone: timeZone)
        : TimezoneHelper.decodeTimestamp(micros, timeZone: timeZone);
    if (value == null) {
      throw ArgumentError('Timestamp value is infinity');
    }
    return value;
  }

  @override
  Uint8List write(DateTime value, {Encoding encoding = utf8}) {
    final diff = timestampTz
        ? TimezoneHelper.encodeTimestampTz(value)
        : TimezoneHelper.encodeTimestamp(value, timeZone: timeZone);
    final bd = ByteData(8);
    bd.setInt64(0, diff);
    return bd.buffer.asUint8List();
  }
}

class DateHandler extends TypeHandler<DateTime> {
  const DateHandler({this.timeZone = const TimeZoneSettings.utc()});

  final TimeZoneSettings timeZone;

  @override
  int get oid => Oid.date;

  @override
  DateTime read(Uint8List buffer,
      {bool isText = false, Encoding encoding = utf8}) {
    DateTime? value;
    if (isText) {
      value = TimezoneHelper.decodeDateText(
        encoding.decode(buffer),
        timeZone: timeZone,
      );
      if (value == null) {
        throw ArgumentError('Date value is infinity');
      }
      return value;
    }
    final bd = ByteData.sublistView(buffer);
    final days = bd.getInt32(0);
    value = TimezoneHelper.decodeDate(days, timeZone: timeZone);
    if (value == null) {
      throw ArgumentError('Date value is infinity');
    }
    return value;
  }

  @override
  Uint8List write(DateTime value, {Encoding encoding = utf8}) {
    final diff = TimezoneHelper.encodeDate(value, timeZone: timeZone);
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
      if (buffer.length >= 2 && buffer[0] == 0x5C && buffer[1] == 0x78) {
        final hexLength = buffer.length - 2;
        if (hexLength.isOdd) {
          throw FormatException('Invalid bytea hex length: $hexLength');
        }

        final output = Uint8List(hexLength ~/ 2);
        var writeIndex = 0;
        for (var i = 2; i < buffer.length; i += 2) {
          output[writeIndex++] =
              (_hexValue(buffer[i]) << 4) | _hexValue(buffer[i + 1]);
        }
        return output;
      }

      return _readEscapeBytea(buffer);
    }
    return buffer;
  }

  @override
  Uint8List write(Uint8List value, {Encoding encoding = utf8}) {
    return value;
  }

  static int _hexValue(int codeUnit) {
    if (codeUnit >= 0x30 && codeUnit <= 0x39) {
      return codeUnit - 0x30;
    }
    if (codeUnit >= 0x41 && codeUnit <= 0x46) {
      return codeUnit - 0x41 + 10;
    }
    if (codeUnit >= 0x61 && codeUnit <= 0x66) {
      return codeUnit - 0x61 + 10;
    }
    throw FormatException(
        'Invalid bytea hex digit: ${String.fromCharCode(codeUnit)}');
  }

  static Uint8List _readEscapeBytea(Uint8List buffer) {
    final output = BytesBuilder(copy: false);
    for (var i = 0; i < buffer.length; i++) {
      final value = buffer[i];
      if (value != 0x5C) {
        output.addByte(value);
        continue;
      }

      if (i + 1 >= buffer.length) {
        output.addByte(value);
        continue;
      }

      final next = buffer[i + 1];
      if (next == 0x5C) {
        output.addByte(0x5C);
        i++;
        continue;
      }

      if (i + 3 < buffer.length &&
          _isOctal(buffer[i + 1]) &&
          _isOctal(buffer[i + 2]) &&
          _isOctal(buffer[i + 3])) {
        output.addByte(((buffer[i + 1] - 0x30) << 6) |
            ((buffer[i + 2] - 0x30) << 3) |
            (buffer[i + 3] - 0x30));
        i += 3;
        continue;
      }

      output.addByte(value);
    }
    return output.takeBytes();
  }

  static bool _isOctal(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x37;
}

class UuidHandler extends TypeHandler<dynamic> {
  const UuidHandler();

  @override
  int get oid => Oid.uuid;

  @override
  DpgsqlUuid read(Uint8List buffer,
      {bool isText = false, Encoding encoding = utf8}) {
    if (isText) {
      return DpgsqlUuid.parse(encoding.decode(buffer));
    }
    if (buffer.length != 16) {
      throw FormatException('Invalid uuid length: ${buffer.length}');
    }
    return DpgsqlUuid(buffer);
  }

  @override
  Uint8List write(dynamic value, {Encoding encoding = utf8}) {
    if (value is DpgsqlUuid) {
      return value.toBytes();
    }
    if (value is String) {
      return DpgsqlUuid.parse(value).toBytes();
    }
    if (value is Uint8List) {
      return DpgsqlUuid(value).toBytes();
    }
    if (value is List<int>) {
      return DpgsqlUuid(value).toBytes();
    }
    throw ArgumentError.value(
        value, 'value', 'Expected DpgsqlUuid or UUID text');
  }
}

class BitStringHandler extends TypeHandler<dynamic> {
  const BitStringHandler(this.oid);

  @override
  final int oid;

  @override
  DpgsqlBitString read(Uint8List buffer,
      {bool isText = false, Encoding encoding = utf8}) {
    if (isText) {
      return DpgsqlBitString(encoding.decode(buffer));
    }
    if (buffer.length < 4) {
      throw FormatException('Invalid bit string length: ${buffer.length}');
    }
    final bitLength = ByteData.sublistView(buffer, 0, 4).getInt32(0);
    if (bitLength < 0) {
      throw FormatException('Invalid bit string bit length: $bitLength');
    }
    final byteLength = (bitLength + 7) >> 3;
    if (buffer.length != 4 + byteLength) {
      throw FormatException(
          'Invalid bit string payload length: ${buffer.length}');
    }

    final result = StringBuffer();
    for (var bit = 0; bit < bitLength; bit++) {
      final byte = buffer[4 + (bit >> 3)];
      final mask = 0x80 >> (bit & 7);
      result.write((byte & mask) == 0 ? '0' : '1');
    }
    return DpgsqlBitString(result.toString());
  }

  @override
  Uint8List write(dynamic value, {Encoding encoding = utf8}) {
    final bits = value is DpgsqlBitString ? value.value : value.toString();
    final bitString = DpgsqlBitString(bits);
    final bitLength = bitString.length;
    final byteLength = (bitLength + 7) >> 3;
    final output = Uint8List(4 + byteLength);
    ByteData.sublistView(output, 0, 4).setInt32(0, bitLength);

    for (var bit = 0; bit < bitLength; bit++) {
      if (bitString.value.codeUnitAt(bit) == 0x31) {
        output[4 + (bit >> 3)] |= 0x80 >> (bit & 7);
      }
    }
    return output;
  }
}

class InetHandler extends TypeHandler<dynamic> {
  const InetHandler(this.oid);

  @override
  final int oid;

  bool get _isCidr => oid == Oid.cidr;

  @override
  DpgsqlInet read(Uint8List buffer,
      {bool isText = false, Encoding encoding = utf8}) {
    if (isText) {
      final text = encoding.decode(buffer);
      return _isCidr ? DpgsqlCidr.parse(text) : DpgsqlInet.parse(text);
    }
    if (buffer.length < 4) {
      throw FormatException('Invalid inet/cidr length: ${buffer.length}');
    }

    final family = buffer[0];
    final prefixLength = buffer[1];
    final addressLength = buffer[3];
    if (buffer.length != 4 + addressLength) {
      throw FormatException(
          'Invalid inet/cidr payload length: ${buffer.length}');
    }

    final addressBytes = Uint8List.sublistView(buffer, 4);
    final address = switch (family) {
      2 => InternetAddress.fromRawAddress(
          addressBytes,
          type: InternetAddressType.IPv4,
        ).address,
      3 => InternetAddress.fromRawAddress(
          addressBytes,
          type: InternetAddressType.IPv6,
        ).address,
      _ => throw FormatException('Invalid inet/cidr address family: $family'),
    };

    return _isCidr
        ? DpgsqlCidr(address, prefixLength: prefixLength)
        : DpgsqlInet(address, prefixLength: prefixLength);
  }

  @override
  Uint8List write(dynamic value, {Encoding encoding = utf8}) {
    final inet = value is DpgsqlInet
        ? value
        : (_isCidr
            ? DpgsqlCidr.parse(value.toString())
            : DpgsqlInet.parse(value.toString()));
    final addressBytes = inet.toBytes();
    final output = Uint8List(4 + addressBytes.length);
    output[0] = addressBytes.length == 4 ? 2 : 3;
    output[1] = inet.effectivePrefixLength;
    output[2] = _isCidr ? 1 : 0;
    output[3] = addressBytes.length;
    output.setRange(4, output.length, addressBytes);
    return output;
  }
}

class MacAddressHandler extends TypeHandler<dynamic> {
  const MacAddressHandler(this.oid);

  @override
  final int oid;

  int get _expectedLength => oid == Oid.macaddr8 ? 8 : 6;

  @override
  DpgsqlMacAddress read(Uint8List buffer,
      {bool isText = false, Encoding encoding = utf8}) {
    if (isText) {
      return DpgsqlMacAddress.parse(encoding.decode(buffer));
    }
    if (buffer.length != _expectedLength) {
      throw FormatException('Invalid macaddr payload length: ${buffer.length}');
    }
    return DpgsqlMacAddress(buffer);
  }

  @override
  Uint8List write(dynamic value, {Encoding encoding = utf8}) {
    final mac = value is DpgsqlMacAddress
        ? value
        : DpgsqlMacAddress.parse(value.toString());
    if (mac.length != _expectedLength) {
      throw FormatException(
        'Expected $_expectedLength bytes for ${oid == Oid.macaddr8 ? 'macaddr8' : 'macaddr'}',
      );
    }
    return mac.toBytes();
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
  static const TypeHandler<DpgsqlDecimal> _dpgsqlDecimalHandler =
      DpgsqlDecimalHandler();

  TypeHandlerRegistry({
    bool useDpgsqlTypes = false,
    bool useCustomDecimal = false,
    TimeZoneSettings timeZone = const TimeZoneSettings.utc(),
  }) {
    register(const TextHandler());
    register(const IntegerHandler());
    register(const BooleanHandler());
    register(const FloatHandler());
    register(const DoubleHandler());
    register(const ByteaHandler());
    register(const UuidHandler());
    register(const BitStringHandler(Oid.bit));
    register(const BitStringHandler(Oid.varbit));
    register(const InetHandler(Oid.inet));
    register(const InetHandler(Oid.cidr));
    register(const MacAddressHandler(Oid.macaddr));
    register(const MacAddressHandler(Oid.macaddr8));

    if (useDpgsqlTypes) {
      register(const DpgsqlDateHandler());
      register(const DpgsqlTimeHandler());
      register(const DpgsqlTimestampHandler());
      register(TimestampHandler(timeZone: timeZone, timestampTz: true));
    } else {
      register(DateHandler(timeZone: timeZone));
      register(TimestampHandler(timeZone: timeZone));
      register(TimestampHandler(timeZone: timeZone, timestampTz: true));
    }

    register(const DpgsqlIntervalHandler());
    register(const DpgsqlMoneyHandler());
    if (useDpgsqlTypes || useCustomDecimal) {
      register(_dpgsqlDecimalHandler);
    } else {
      register(const NumericDoubleHandler());
    }

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
    register(RangeHandler<DateTime>(
        Oid.tsrange, TimestampHandler(timeZone: timeZone)));
    register(RangeHandler<DateTime>(Oid.tstzrange,
        TimestampHandler(timeZone: timeZone, timestampTz: true)));
    register(
        RangeHandler<DateTime>(Oid.daterange, DateHandler(timeZone: timeZone)));

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
    if (value is DpgsqlUuid) return _oidHandlers[Oid.uuid];
    if (value is DpgsqlBitString) return _oidHandlers[Oid.varbit];
    if (value is DpgsqlCidr) return _oidHandlers[Oid.cidr];
    if (value is DpgsqlInet) return _oidHandlers[Oid.inet];
    if (value is DpgsqlMacAddress) {
      return _oidHandlers[value.length == 8 ? Oid.macaddr8 : Oid.macaddr];
    }

    // Dpgsql Types
    if (value is DpgsqlDate) return _oidHandlers[Oid.date];
    if (value is DpgsqlTime) return _oidHandlers[Oid.time];
    if (value is DpgsqlTimestamp) return _oidHandlers[Oid.timestamp];
    if (value is DpgsqlInterval) return _oidHandlers[Oid.interval];
    if (value is DpgsqlMoney) return _oidHandlers[Oid.money];
    if (value is DpgsqlDecimal) return _dpgsqlDecimalHandler;

    // Geometric Types
    if (value is DpgsqlPoint) return _oidHandlers[Oid.point];
    if (value is DpgsqlBox) return _oidHandlers[Oid.box];
    if (value is DpgsqlLSeg) return _oidHandlers[Oid.lseg];
    if (value is DpgsqlLine) return _oidHandlers[Oid.line];
    if (value is DpgsqlPath) return _oidHandlers[Oid.path];
    if (value is DpgsqlPolygon) return _oidHandlers[Oid.polygon];
    if (value is DpgsqlCircle) return _oidHandlers[Oid.circle];

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
    if (T == DpgsqlUuid) return _oidHandlers[Oid.uuid] as TypeHandler<T>?;
    if (T == DpgsqlBitString)
      return _oidHandlers[Oid.varbit] as TypeHandler<T>?;
    if (T == DpgsqlInet) return _oidHandlers[Oid.inet] as TypeHandler<T>?;
    if (T == DpgsqlCidr) return _oidHandlers[Oid.cidr] as TypeHandler<T>?;
    if (T == DpgsqlMacAddress) {
      return _oidHandlers[Oid.macaddr] as TypeHandler<T>?;
    }

    if (T == DpgsqlDate) return _oidHandlers[Oid.date] as TypeHandler<T>?;
    if (T == DpgsqlTime) return _oidHandlers[Oid.time] as TypeHandler<T>?;
    if (T == DpgsqlTimestamp)
      return _oidHandlers[Oid.timestamp] as TypeHandler<T>?;
    if (T == DpgsqlInterval)
      return _oidHandlers[Oid.interval] as TypeHandler<T>?;
    if (T == DpgsqlMoney) return _oidHandlers[Oid.money] as TypeHandler<T>?;
    if (T == DpgsqlDecimal) return _dpgsqlDecimalHandler as TypeHandler<T>?;

    if (T == DpgsqlPoint) return _oidHandlers[Oid.point] as TypeHandler<T>?;
    if (T == DpgsqlBox) return _oidHandlers[Oid.box] as TypeHandler<T>?;
    if (T == DpgsqlLSeg) return _oidHandlers[Oid.lseg] as TypeHandler<T>?;
    if (T == DpgsqlLine) return _oidHandlers[Oid.line] as TypeHandler<T>?;
    if (T == DpgsqlPath) return _oidHandlers[Oid.path] as TypeHandler<T>?;
    if (T == DpgsqlPolygon) return _oidHandlers[Oid.polygon] as TypeHandler<T>?;
    if (T == DpgsqlCircle) return _oidHandlers[Oid.circle] as TypeHandler<T>?;

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

  TypeHandler? resolveByDpgsqlDbType(DpgsqlDbType dbType) {
    switch (dbType) {
      case DpgsqlDbType.bigint:
        return _oidHandlers[Oid.int8];
      case DpgsqlDbType.boolean:
        return _oidHandlers[Oid.bool];
      case DpgsqlDbType.box:
        return _oidHandlers[Oid.box];
      case DpgsqlDbType.bytea:
        return _oidHandlers[Oid.bytea];
      case DpgsqlDbType.circle:
        return _oidHandlers[Oid.circle];
      case DpgsqlDbType.char:
        return _oidHandlers[Oid.bpchar];
      case DpgsqlDbType.date:
        return _oidHandlers[Oid.date];
      case DpgsqlDbType.double:
        return _oidHandlers[Oid.float8];
      case DpgsqlDbType.integer:
        return _oidHandlers[Oid.int4];
      case DpgsqlDbType.json:
        return _oidHandlers[Oid.json];
      case DpgsqlDbType.jsonb:
        return _oidHandlers[Oid.jsonb];
      case DpgsqlDbType.inet:
        return _oidHandlers[Oid.inet];
      case DpgsqlDbType.cidr:
        return _oidHandlers[Oid.cidr];
      case DpgsqlDbType.macaddr:
        return _oidHandlers[Oid.macaddr];
      case DpgsqlDbType.macaddr8:
        return _oidHandlers[Oid.macaddr8];
      case DpgsqlDbType.line:
        return _oidHandlers[Oid.line];
      case DpgsqlDbType.lSeg:
        return _oidHandlers[Oid.lseg];
      case DpgsqlDbType.money:
        return _oidHandlers[Oid.money];
      case DpgsqlDbType.numeric:
        return _oidHandlers[Oid.numeric];
      case DpgsqlDbType.path:
        return _oidHandlers[Oid.path];
      case DpgsqlDbType.point:
        return _oidHandlers[Oid.point];
      case DpgsqlDbType.polygon:
        return _oidHandlers[Oid.polygon];
      case DpgsqlDbType.real:
        return _oidHandlers[Oid.float4];
      case DpgsqlDbType.smallint:
        return _oidHandlers[Oid.int2];
      case DpgsqlDbType.text:
        return _oidHandlers[Oid.text];
      case DpgsqlDbType.time:
        return _oidHandlers[Oid.time];
      case DpgsqlDbType.timestamp:
        return _oidHandlers[Oid.timestamp];
      case DpgsqlDbType.timestampTz:
        return _oidHandlers[Oid.timestamptz];
      case DpgsqlDbType.uuid:
        return _oidHandlers[Oid.uuid];
      case DpgsqlDbType.bit:
        return _oidHandlers[Oid.bit];
      case DpgsqlDbType.varbit:
        return _oidHandlers[Oid.varbit];
      case DpgsqlDbType.varchar:
        return _oidHandlers[Oid.varchar];
      case DpgsqlDbType.xml:
        return _oidHandlers[Oid.xml];
      case DpgsqlDbType.unknown:
        return _oidHandlers[Oid.unknown];
      case DpgsqlDbType.integerRange:
        return resolve(Oid.int4range);
      case DpgsqlDbType.bigIntRange:
        return resolve(Oid.int8range);
      case DpgsqlDbType.numRange:
        return resolve(Oid.numrange);
      case DpgsqlDbType.tsRange:
        return resolve(Oid.tsrange);
      case DpgsqlDbType.tsTzRange:
        return resolve(Oid.tstzrange);
      case DpgsqlDbType.dateRange:
        return resolve(Oid.daterange);
    }
  }
}
