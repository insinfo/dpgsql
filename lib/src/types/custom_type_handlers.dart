import 'dart:typed_data';
import 'dart:convert';
import 'type_handler.dart';
import 'oid.dart';
import 'dpgsql_types.dart';

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
    final sign = bd.getInt16(offset);
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

    final bd = ByteData.sublistView(buffer);
    var offset = 0;
    final ndigits = bd.getInt16(offset);
    offset += 2;
    final weight = bd.getInt16(offset);
    offset += 2;
    final sign = bd.getInt16(offset);
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
      value = (value * 10000) + bd.getInt16(offset);
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

  @override
  Uint8List write(double value, {Encoding encoding = utf8}) {
    return const DpgsqlDecimalHandler().write(DpgsqlDecimal.parse('$value'));
  }
}
