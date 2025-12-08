import 'dart:typed_data';
import 'dart:convert';
import 'type_handler.dart';
import 'oid.dart';
import 'npgsql_types.dart';

class NpgsqlDateHandler extends TypeHandler<NpgsqlDate> {
  const NpgsqlDateHandler();

  @override
  int get oid => Oid.date;

  @override
  NpgsqlDate read(Uint8List buffer,
      {bool isText = false, Encoding encoding = utf8}) {
    if (isText) {
      final str = encoding.decode(buffer);
      return NpgsqlDate.parse(str);
    }
    final bd = ByteData.sublistView(buffer);
    final days = bd.getInt32(0);
    return NpgsqlDate(days);
  }

  @override
  Uint8List write(NpgsqlDate value, {Encoding encoding = utf8}) {
    final bd = ByteData(4);
    bd.setInt32(0, value.days);
    return bd.buffer.asUint8List();
  }
}

class NpgsqlTimeHandler extends TypeHandler<NpgsqlTime> {
  const NpgsqlTimeHandler();

  @override
  int get oid => Oid.time;

  @override
  NpgsqlTime read(Uint8List buffer,
      {bool isText = false, Encoding encoding = utf8}) {
    if (isText) {
      final str = encoding.decode(buffer);
      return NpgsqlTime.parse(str);
    }
    final bd = ByteData.sublistView(buffer);
    final micros = bd.getInt64(0);
    return NpgsqlTime(micros);
  }

  @override
  Uint8List write(NpgsqlTime value, {Encoding encoding = utf8}) {
    final bd = ByteData(8);
    bd.setInt64(0, value.microseconds);
    return bd.buffer.asUint8List();
  }
}

class NpgsqlTimestampHandler extends TypeHandler<NpgsqlTimestamp> {
  const NpgsqlTimestampHandler();

  @override
  int get oid => Oid.timestamp;

  @override
  NpgsqlTimestamp read(Uint8List buffer,
      {bool isText = false, Encoding encoding = utf8}) {
    if (isText) {
      final str = encoding.decode(buffer);
      return NpgsqlTimestamp.parse(str);
    }
    final bd = ByteData.sublistView(buffer);
    final micros = bd.getInt64(0);
    return NpgsqlTimestamp(micros);
  }

  @override
  Uint8List write(NpgsqlTimestamp value, {Encoding encoding = utf8}) {
    final bd = ByteData(8);
    bd.setInt64(0, value.microseconds);
    return bd.buffer.asUint8List();
  }
}

class NpgsqlMoneyHandler extends TypeHandler<NpgsqlMoney> {
  const NpgsqlMoneyHandler();

  @override
  int get oid => Oid.money;

  @override
  NpgsqlMoney read(Uint8List buffer,
      {bool isText = false, Encoding encoding = utf8}) {
    if (isText) {
      final str = encoding.decode(buffer);
      return NpgsqlMoney.parse(str);
    }
    final bd = ByteData.sublistView(buffer);
    final val = bd.getInt64(0);
    return NpgsqlMoney(val);
  }

  @override
  Uint8List write(NpgsqlMoney value, {Encoding encoding = utf8}) {
    final bd = ByteData(8);
    bd.setInt64(0, value.value);
    return bd.buffer.asUint8List();
  }
}

class NpgsqlIntervalHandler extends TypeHandler<NpgsqlInterval> {
  const NpgsqlIntervalHandler();

  @override
  int get oid => Oid.interval;

  @override
  NpgsqlInterval read(Uint8List buffer,
      {bool isText = false, Encoding encoding = utf8}) {
    if (isText) {
      final str = encoding.decode(buffer);
      return NpgsqlInterval.parse(str);
    }
    final bd = ByteData.sublistView(buffer);
    // 16 bytes: time(8), days(4), months(4)
    final time = bd.getInt64(0);
    final days = bd.getInt32(8);
    final months = bd.getInt32(12);
    return NpgsqlInterval(months: months, days: days, time: time);
  }

  @override
  Uint8List write(NpgsqlInterval value, {Encoding encoding = utf8}) {
    final bd = ByteData(16);
    bd.setInt64(0, value.time);
    bd.setInt32(8, value.days);
    bd.setInt32(12, value.months);
    return bd.buffer.asUint8List();
  }
}

class NpgsqlDecimalHandler extends TypeHandler<NpgsqlDecimal> {
  const NpgsqlDecimalHandler();

  @override
  int get oid => Oid.numeric;

  @override
  NpgsqlDecimal read(Uint8List buffer,
      {bool isText = false, Encoding encoding = utf8}) {
    if (isText) {
      final str = encoding.decode(buffer);
      return NpgsqlDecimal.parse(str);
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

    return NpgsqlDecimal(
        ndigits: ndigits,
        weight: weight,
        sign: sign,
        dscale: dscale,
        digits: digits);
  }

  @override
  Uint8List write(NpgsqlDecimal value, {Encoding encoding = utf8}) {
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
