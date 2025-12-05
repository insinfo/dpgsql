import 'dart:convert';

import 'package:dpgsql/src/types/geometric_handlers.dart';
import 'package:dpgsql/src/types/json_handler.dart';
import 'package:dpgsql/src/types/npgsql_geometric.dart';
import 'package:dpgsql/src/types/npgsql_range.dart';
import 'package:dpgsql/src/types/range_handlers.dart';
import 'package:dpgsql/src/types/type_handler.dart';
import 'package:test/test.dart';

void main() {
  group('JSON Types', () {
    test('JsonHandler read/write', () {
      const handler = JsonHandler();
      const json = '{"a":1}';
      final bytes = handler.write(json);
      expect(utf8.decode(bytes), json);
      expect(handler.read(bytes), json);
    });

    test('JsonbHandler read/write', () {
      const handler = JsonbHandler();
      const json = '{"a":1}';
      final bytes = handler.write(json);
      expect(bytes[0], 1); // Version 1
      expect(utf8.decode(bytes.sublist(1)), json);
      expect(handler.read(bytes), json);
    });
  });

  group('Geometric Types', () {
    test('PointHandler', () {
      const handler = PointHandler();
      const p = NpgsqlPoint(1.5, 2.5);
      final bytes = handler.write(p);
      expect(bytes.length, 16);
      expect(handler.read(bytes), p);
    });

    test('BoxHandler', () {
      const handler = BoxHandler();
      const b = NpgsqlBox(NpgsqlPoint(10, 10), NpgsqlPoint(0, 0));
      final bytes = handler.write(b);
      expect(bytes.length, 32);
      final read = handler.read(bytes);
      expect(read.upperRight, b.upperRight);
      expect(read.lowerLeft, b.lowerLeft);
    });

    test('PathHandler', () {
      const handler = PathHandler();
      const p = NpgsqlPath([NpgsqlPoint(0, 0), NpgsqlPoint(1, 1)], open: true);
      final bytes = handler.write(p);
      // 1 (bool) + 4 (count) + 16*2 (points) = 37 bytes
      expect(bytes.length, 37);
      final read = handler.read(bytes);
      expect(read.open, true);
      expect(read.points.length, 2);
      expect(read.points[0], p.points[0]);
    });
  });

  group('Range Types', () {
    test('Int4RangeHandler', () {
      final handler = RangeHandler<int>(0, const IntegerHandler());
      const r = NpgsqlRange(lowerBound: 1, upperBound: 10);
      final bytes = handler.write(r);
      // Flags(1) + Len(4)+Val(4) + Len(4)+Val(4) = 1 + 8 + 8 = 17 bytes
      expect(bytes.length, 17);
      final read = handler.read(bytes);
      expect(read, r);
    });

    test('Int4RangeHandler Empty', () {
      final handler = RangeHandler<int>(0, const IntegerHandler());
      const r = NpgsqlRange<int>.empty();
      final bytes = handler.write(r);
      expect(bytes.length, 1);
      expect(bytes[0], 0x01); // Empty flag
      final read = handler.read(bytes);
      expect(read.isEmpty, true);
    });

    test('Int4RangeHandler Infinite', () {
      final handler = RangeHandler<int>(0, const IntegerHandler());
      const r = NpgsqlRange<int>(lowerBoundInfinite: true, upperBound: 5);
      final bytes = handler.write(r);
      // Flags(1) + UpperBound(8) = 9 bytes?
      // Flags: LowerInfinite(0x08) | LowerInclusive(0x02 default) -> 0x0A?
      // Wait, default lowerBoundInclusive is true.
      // But if infinite, inclusive is ignored usually?
      // Let's check write logic.
      // if (value.lowerBoundInclusive) flags |= 0x02;
      // if (value.lowerBoundInfinite) flags |= 0x08;

      final read = handler.read(bytes);
      expect(read.lowerBoundInfinite, true);
      expect(read.upperBound, 5);
    });
  });
}
