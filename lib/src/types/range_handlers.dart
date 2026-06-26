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
      // TODO: Text parsing for ranges
      throw UnimplementedError('Text parsing for Range not implemented');
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
}
