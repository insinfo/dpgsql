import 'dart:typed_data';
import 'dart:convert';
import 'type_handler.dart';
import 'oid.dart';
import 'dpgsql_types.dart';
import 'pg_binary_text.dart';

class DpgsqlDateHandler extends TypeHandler<DpgsqlDate> {
  const DpgsqlDateHandler();

  @override
  int get oid => Oid.date;

  @override
  DpgsqlDate read(Uint8List buffer,
      {bool isText = false, Encoding encoding = utf8}) {
    if (isText) {
      final str = encoding.decode(buffer);
      return DpgsqlDate.parse(str);
    }
    final bd = ByteData.sublistView(buffer);
    final days = bd.getInt32(0);
    return DpgsqlDate(days);
  }

  @override
  Uint8List write(DpgsqlDate value, {Encoding encoding = utf8}) {
    final bd = ByteData(4);
    bd.setInt32(0, value.days);
    return bd.buffer.asUint8List();
  }
}

class DpgsqlTimeHandler extends TypeHandler<DpgsqlTime> {
  const DpgsqlTimeHandler();

  @override
  int get oid => Oid.time;

  @override
  DpgsqlTime read(Uint8List buffer,
      {bool isText = false, Encoding encoding = utf8}) {
    if (isText) {
      final str = encoding.decode(buffer);
      return DpgsqlTime.parse(str);
    }
    final bd = ByteData.sublistView(buffer);
    final micros = bd.getInt64(0);
    return DpgsqlTime(micros);
  }

  @override
  Uint8List write(DpgsqlTime value, {Encoding encoding = utf8}) {
    final bd = ByteData(8);
    bd.setInt64(0, value.microseconds);
    return bd.buffer.asUint8List();
  }
}

class DpgsqlTimestampHandler extends TypeHandler<DpgsqlTimestamp> {
  const DpgsqlTimestampHandler();

  @override
  int get oid => Oid.timestamp;

  @override
  DpgsqlTimestamp read(Uint8List buffer,
      {bool isText = false, Encoding encoding = utf8}) {
    if (isText) {
      final str = encoding.decode(buffer);
      return DpgsqlTimestamp.parse(str);
    }
    final bd = ByteData.sublistView(buffer);
    final micros = bd.getInt64(0);
    return DpgsqlTimestamp(micros);
  }

  @override
  Uint8List write(DpgsqlTimestamp value, {Encoding encoding = utf8}) {
    final bd = ByteData(8);
    bd.setInt64(0, value.microseconds);
    return bd.buffer.asUint8List();
  }
}

class DpgsqlMoneyHandler extends TypeHandler<DpgsqlMoney> {
  const DpgsqlMoneyHandler();

  @override
  int get oid => Oid.money;

  @override
  DpgsqlMoney read(Uint8List buffer,
      {bool isText = false, Encoding encoding = utf8}) {
    if (isText) {
      final str = encoding.decode(buffer);
      return DpgsqlMoney.parse(str);
    }
    final bd = ByteData.sublistView(buffer);
    final val = bd.getInt64(0);
    return DpgsqlMoney(val);
  }

  @override
  Uint8List write(DpgsqlMoney value, {Encoding encoding = utf8}) {
    final bd = ByteData(8);
    bd.setInt64(0, value.value);
    return bd.buffer.asUint8List();
  }
}

class DpgsqlIntervalHandler extends TypeHandler<DpgsqlInterval> {
  const DpgsqlIntervalHandler();

  @override
  int get oid => Oid.interval;

  @override
  DpgsqlInterval read(Uint8List buffer,
      {bool isText = false, Encoding encoding = utf8}) {
    if (isText) {
      final str = encoding.decode(buffer);
      return DpgsqlInterval.parse(str);
    }
    final bd = ByteData.sublistView(buffer);
    // 16 bytes: time(8), days(4), months(4)
    final time = bd.getInt64(0);
    final days = bd.getInt32(8);
    final months = bd.getInt32(12);
    return DpgsqlInterval(months: months, days: days, time: time);
  }

  @override
  Uint8List write(DpgsqlInterval value, {Encoding encoding = utf8}) {
    final bd = ByteData(16);
    bd.setInt64(0, value.time);
    bd.setInt32(8, value.days);
    bd.setInt32(12, value.months);
    return bd.buffer.asUint8List();
  }
}

class DpgsqlDecimalHandler extends TypeHandler<DpgsqlDecimal> {
  const DpgsqlDecimalHandler();

  @override
  int get oid => Oid.numeric;

  @override
  DpgsqlDecimal read(Uint8List buffer,
      {bool isText = false, Encoding encoding = utf8}) {
    if (isText) {
      final str = encoding.decode(buffer);
      return DpgsqlDecimal.parse(str);
    }
    final bd = ByteData.sublistView(buffer);
    int offset = 0;
    final ndigits = bd.getInt16(offset);
    offset += 2;
    final weight = bd.getInt16(offset);
    offset += 2;
    final sign = bd.getUint16(offset); // 0xC000 (NaN) read signed was negative
    offset += 2;
    final dscale = bd.getInt16(offset);
    offset += 2;

    final digits = <int>[];
    for (int i = 0; i < ndigits; i++) {
      digits.add(bd.getInt16(offset));
      offset += 2;
    }

    return DpgsqlDecimal(
        ndigits: ndigits,
        weight: weight,
        sign: sign,
        dscale: dscale,
        digits: digits);
  }

  @override
  Uint8List write(DpgsqlDecimal value, {Encoding encoding = utf8}) {
    final len = 8 + (value.digits.length * 2);
    final bd = ByteData(len);
    int offset = 0;
    bd.setInt16(offset, value.ndigits);
    offset += 2;
    bd.setInt16(offset, value.weight);
    offset += 2;
    bd.setInt16(offset, value.sign);
    offset += 2;
    bd.setInt16(offset, value.dscale);
    offset += 2;
    for (final d in value.digits) {
      bd.setInt16(offset, d);
      offset += 2;
    }
    return bd.buffer.asUint8List();
  }
}

/// A type without a natural Dart type as the text the server prints for it
/// (`Decode Extended Types As Text`): intervals, geometric types, bit
/// strings, tsvector, ranges, time with time zone... `money` is the decimal
/// amount (`'12.34'`), not the lc_monetary text. Parameters are written by
/// [writer], the type's own handler.
class ServerTextHandler extends TypeHandler<Object> {
  const ServerTextHandler(this.oid, [this.writer]);

  @override
  final int oid;

  final TypeHandler? writer;

  @override
  String read(Uint8List buffer,
      {bool isText = false, Encoding encoding = utf8}) {
    if (isText) {
      final text = encoding.decode(buffer);
      return oid == PgBinaryText.oidMoney
          ? PgBinaryText.moneyFromText(text)
          : text;
    }
    return PgBinaryText.scalar(oid, buffer) ?? encoding.decode(buffer);
  }

  @override
  Uint8List write(Object value, {Encoding encoding = utf8}) {
    final writer = this.writer;
    if (writer == null) {
      throw ArgumentError.value(
          value, 'value', 'No parameter encoder for the type with OID $oid');
    }
    return writer.write(value, encoding: encoding);
  }
}

/// `numeric` as its exact decimal text (`Decode Numeric As String`).
///
/// Typed `Object` so a `DpgsqlDbType.numeric` parameter may be a `String`,
/// a `num` or a [DpgsqlDecimal]; values are read as `String`.
class NumericStringHandler extends TypeHandler<Object> {
  const NumericStringHandler();

  @override
  int get oid => Oid.numeric;

  @override
  String read(Uint8List buffer,
      {bool isText = false, Encoding encoding = utf8}) {
    if (isText) return encoding.decode(buffer);
    return decodeBinary(buffer, 0, buffer.length);
  }

  @override
  Uint8List write(Object value, {Encoding encoding = utf8}) {
    final decimal =
        value is DpgsqlDecimal ? value : DpgsqlDecimal.parse('$value');
    return const DpgsqlDecimalHandler().write(decimal);
  }

  /// The text PostgreSQL prints for the binary numeric at [offset] of
  /// [payload] (`numeric_out`): base-10000 digit groups, `dscale` fraction
  /// digits, `NaN`/`Infinity`/`-Infinity`.
  static String decodeBinary(Uint8List payload, int offset, int length) {
    if (length < 8) {
      throw FormatException('Invalid numeric length: $length');
    }
    final bd = ByteData.sublistView(payload, offset, offset + length);
    final ndigits = bd.getInt16(0);
    final weight = bd.getInt16(2);
    final sign = bd.getUint16(4);
    final dscale = bd.getInt16(6);
    if (sign == 0xC000) return 'NaN';
    if (sign == 0xD000) return 'Infinity';
    if (sign == 0xF000) return '-Infinity';
    if (8 + ndigits * 2 > length) {
      throw FormatException('Invalid numeric digit length: $length');
    }
    int digit(int index) =>
        index >= 0 && index < ndigits ? bd.getInt16(8 + index * 2) : 0;

    final text = StringBuffer(sign == 0x4000 ? '-' : '');
    if (weight < 0) {
      text.write('0');
    } else {
      for (var i = 0; i <= weight; i++) {
        final group = '${digit(i)}';
        text.write(i == 0 ? group : group.padLeft(4, '0'));
      }
    }
    if (dscale > 0) {
      final fraction = StringBuffer();
      for (var i = weight + 1; fraction.length < dscale; i++) {
        fraction.write('${digit(i)}'.padLeft(4, '0'));
      }
      text
        ..write('.')
        ..write(fraction.toString().substring(0, dscale));
    }
    return text.toString();
  }
}

class NumericDoubleHandler extends TypeHandler<double> {
  const NumericDoubleHandler();

  @override
  int get oid => Oid.numeric;

  @override
  double read(Uint8List buffer,
      {bool isText = false, Encoding encoding = utf8}) {
    if (isText) {
      return double.parse(encoding.decode(buffer));
    }

    return decodeBinary(buffer, 0, buffer.length);
  }

  static const _powersOfTen = [
    1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, //
    1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22,
  ];

  /// The double nearest to the binary numeric at [offset] of [payload]: the
  /// value `double.parse` gives for its text. The base-10000 digits used to
  /// be accumulated with `*` and `/`, rounding at each step, so the binary
  /// format could differ from the text one in the last bits; NaN and the
  /// infinities (sign word read as signed) came back as 0.0.
  static double decodeBinary(Uint8List payload, int offset, int length) {
    if (length < 8) {
      throw FormatException('Invalid numeric length: $length');
    }
    final bd = ByteData.sublistView(payload, offset, offset + length);
    final ndigits = bd.getInt16(0);
    final weight = bd.getInt16(2);
    final sign = bd.getUint16(4);
    if (sign == 0xC000) return double.nan;
    if (sign == 0xD000) return double.infinity;
    if (sign == 0xF000) return double.negativeInfinity;
    if (ndigits == 0) return sign == 0x4000 ? -0.0 : 0.0;
    if (8 + ndigits * 2 > length) {
      throw FormatException('Invalid numeric digit length: $length');
    }

    // value = digits * 10^exponent.
    final exponent = (weight - ndigits + 1) * 4;
    if (ndigits <= 3 && exponent.abs() <= 22) {
      // Exact integer (< 10^12) and power of ten: one correctly rounded
      // operation, the same double as parsing the text.
      var digits = 0;
      for (var i = 0; i < ndigits; i++) {
        digits = digits * 10000 + bd.getInt16(8 + i * 2);
      }
      final value = exponent >= 0
          ? digits * _powersOfTen[exponent]
          : digits / _powersOfTen[-exponent];
      return sign == 0x4000 ? -value : value;
    }
    final text = StringBuffer(sign == 0x4000 ? '-' : '');
    for (var i = 0; i < ndigits; i++) {
      final group = '${bd.getInt16(8 + i * 2)}';
      text.write(i == 0 ? group : group.padLeft(4, '0'));
    }
    text
      ..write('e')
      ..write(exponent);
    return double.parse(text.toString());
  }

  @override
  Uint8List write(double value, {Encoding encoding = utf8}) {
    return const DpgsqlDecimalHandler().write(DpgsqlDecimal.parse('$value'));
  }
}
