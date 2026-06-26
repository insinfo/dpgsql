import 'dart:typed_data';
import 'dart:convert';
import 'type_handler.dart';
import 'dpgsql_range.dart';

class RangeHandler<T> extends TypeHandler<DpgsqlRange<T>> {
  RangeHandler(this.oid, this.elementHandler);

  @override
  final int oid;
  final TypeHandler<T> elementHandler;

  @override
  DpgsqlRange<T> read(Uint8List buffer,
      {bool isText = false, Encoding encoding = utf8}) {
    if (isText) {
      return _readTextRange(encoding.decode(buffer), encoding);
    }

    if (buffer.isEmpty) return DpgsqlRange.empty();

    final bd = ByteData.sublistView(buffer);
    final flags = buffer[0];

    final isEmpty = (flags & 0x01) != 0;
    if (isEmpty) return DpgsqlRange<T>.empty();

    final lowerBoundInclusive = (flags & 0x02) != 0;
    final upperBoundInclusive = (flags & 0x04) != 0;
    final lowerBoundInfinite = (flags & 0x08) != 0;
    final upperBoundInfinite = (flags & 0x10) != 0;

    int offset = 1;
    T? lowerBound;
    T? upperBound;

    if (!lowerBoundInfinite) {
      final len = bd.getInt32(offset);
      offset += 4;
      if (len != -1) {
        final elemBytes = buffer.sublist(offset, offset + len);
        lowerBound = elementHandler.read(elemBytes, encoding: encoding);
        offset += len;
      }
    }

    if (!upperBoundInfinite) {
      final len = bd.getInt32(offset);
      offset += 4;
      if (len != -1) {
        final elemBytes = buffer.sublist(offset, offset + len);
        upperBound = elementHandler.read(elemBytes, encoding: encoding);
        offset += len;
      }
    }

    return DpgsqlRange<T>(
      lowerBound: lowerBound,
      upperBound: upperBound,
      lowerBoundInclusive: lowerBoundInclusive,
      upperBoundInclusive: upperBoundInclusive,
      lowerBoundInfinite: lowerBoundInfinite,
      upperBoundInfinite: upperBoundInfinite,
    );
  }

  @override
  Uint8List write(DpgsqlRange<T> value, {Encoding encoding = utf8}) {
    if (value.isEmpty) {
      return Uint8List.fromList([0x01]);
    }

    int flags = 0;
    if (value.lowerBoundInclusive) flags |= 0x02;
    if (value.upperBoundInclusive) flags |= 0x04;
    if (value.lowerBoundInfinite) flags |= 0x08;
    if (value.upperBoundInfinite) flags |= 0x10;

    final parts = <List<int>>[];
    parts.add([flags]);

    if (!value.lowerBoundInfinite) {
      if (value.lowerBound == null) {
        throw ArgumentError('Lower bound cannot be null unless infinite');
      }
      final bytes = elementHandler.write(value.lowerBound!, encoding: encoding);
      final lenBytes = ByteData(4)..setInt32(0, bytes.length);
      parts.add(lenBytes.buffer.asUint8List());
      parts.add(bytes);
    }

    if (!value.upperBoundInfinite) {
      if (value.upperBound == null) {
        throw ArgumentError('Upper bound cannot be null unless infinite');
      }
      final bytes = elementHandler.write(value.upperBound!, encoding: encoding);
      final lenBytes = ByteData(4)..setInt32(0, bytes.length);
      parts.add(lenBytes.buffer.asUint8List());
      parts.add(bytes);
    }

    final totalLen = parts.fold(0, (sum, p) => sum + p.length);
    final result = Uint8List(totalLen);
    int offset = 0;
    for (final p in parts) {
      result.setRange(offset, offset + p.length, p);
      offset += p.length;
    }
    return result;
  }

  DpgsqlRange<T> _readTextRange(String input, Encoding encoding) {
    final text = input.trim();
    if (text.toLowerCase() == 'empty') {
      return DpgsqlRange<T>.empty();
    }
    if (text.length < 3) {
      throw FormatException('Invalid range literal: $input');
    }

    final start = text.codeUnitAt(0);
    final end = text.codeUnitAt(text.length - 1);
    if (start != 0x5B && start != 0x28) {
      throw FormatException('Invalid range lower bound marker: $input');
    }
    if (end != 0x5D && end != 0x29) {
      throw FormatException('Invalid range upper bound marker: $input');
    }

    final lowerInclusive = start == 0x5B;
    final upperInclusive = end == 0x5D;
    final bounds = _splitBounds(text.substring(1, text.length - 1), input);

    final lower = _parseBound(bounds.lower, isLower: true, encoding: encoding);
    final upper = _parseBound(bounds.upper, isLower: false, encoding: encoding);

    if (!lower.infinite &&
        !upper.infinite &&
        lower.value == upper.value &&
        !(lowerInclusive && upperInclusive)) {
      return DpgsqlRange<T>.empty();
    }

    return DpgsqlRange<T>(
      lowerBound: lower.value,
      upperBound: upper.value,
      lowerBoundInclusive: lower.infinite ? false : lowerInclusive,
      upperBoundInclusive: upper.infinite ? false : upperInclusive,
      lowerBoundInfinite: lower.infinite,
      upperBoundInfinite: upper.infinite,
    );
  }

  _RangeBounds _splitBounds(String text, String originalInput) {
    final lower = StringBuffer();
    final upper = StringBuffer();
    var current = lower;
    var inQuotes = false;
    var lowerQuoted = false;
    var upperQuoted = false;
    var foundComma = false;

    for (var i = 0; i < text.length; i++) {
      final char = text.codeUnitAt(i);

      if (char == 0x5C) {
        if (i + 1 >= text.length) {
          current.writeCharCode(char);
          continue;
        }
        current.write(text[i + 1]);
        i++;
        continue;
      }

      if (char == 0x22) {
        inQuotes = !inQuotes;
        if (!foundComma) {
          lowerQuoted = true;
        } else {
          upperQuoted = true;
        }
        continue;
      }

      if (char == 0x2C && !inQuotes) {
        if (foundComma) {
          throw FormatException('Invalid range literal: $originalInput');
        }
        foundComma = true;
        current = upper;
        continue;
      }

      current.writeCharCode(char);
    }

    if (inQuotes || !foundComma) {
      throw FormatException('Invalid range literal: $originalInput');
    }

    return _RangeBounds(
      _RangeBoundText(lower.toString(), lowerQuoted),
      _RangeBoundText(upper.toString(), upperQuoted),
    );
  }

  _RangeBound<T> _parseBound(
    _RangeBoundText bound, {
    required bool isLower,
    required Encoding encoding,
  }) {
    final value = bound.quoted ? bound.text : bound.text.trim();
    if (!bound.quoted) {
      final lowerValue = value.toLowerCase();
      if (value.isEmpty ||
          lowerValue == 'null' ||
          (isLower && lowerValue == '-infinity') ||
          (!isLower && lowerValue == 'infinity')) {
        return _RangeBound<T>.infinite();
      }
    }

    return _RangeBound<T>.finite(
      elementHandler.read(
        Uint8List.fromList(encoding.encode(value)),
        isText: true,
        encoding: encoding,
      ),
    );
  }
}

class _RangeBounds {
  const _RangeBounds(this.lower, this.upper);

  final _RangeBoundText lower;
  final _RangeBoundText upper;
}

class _RangeBoundText {
  const _RangeBoundText(this.text, this.quoted);

  final String text;
  final bool quoted;
}

class _RangeBound<T> {
  const _RangeBound._({required this.infinite, this.value});

  factory _RangeBound.infinite() => _RangeBound<T>._(infinite: true);

  factory _RangeBound.finite(T value) =>
      _RangeBound<T>._(infinite: false, value: value);

  final bool infinite;
  final T? value;
}
