import 'dart:convert';
import 'dart:typed_data';

import 'package:dpgsql/src/types/geometric_handlers.dart';
import 'package:dpgsql/src/types/json_handler.dart';
import 'package:dpgsql/src/types/dpgsql_geometric.dart';
import 'package:dpgsql/src/types/dpgsql_range.dart';
import 'package:dpgsql/src/types/range_handlers.dart';
import 'package:dpgsql/src/types/dpgsql_types.dart';
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

  group('Bytea Types', () {
    test('ByteaHandler parses PostgreSQL hex text format', () {
      const handler = ByteaHandler();
      final result = handler.read(
        Uint8List.fromList(r'\x00ff5c'.codeUnits),
        isText: true,
      );

      expect(result, orderedEquals(<int>[0, 255, 92]));
    });

    test('ByteaHandler parses PostgreSQL escape text format', () {
      const handler = ByteaHandler();
      final result = handler.read(
        Uint8List.fromList(r'abc\\\001'.codeUnits),
        isText: true,
      );

      expect(result, orderedEquals(<int>[97, 98, 99, 92, 1]));
    });
  });

  group('Geometric Types', () {
    test('PointHandler', () {
      const handler = PointHandler();
      const p = DpgsqlPoint(1.5, 2.5);
      final bytes = handler.write(p);
      expect(bytes.length, 16);
      expect(handler.read(bytes), p);
    });

    test('BoxHandler', () {
      const handler = BoxHandler();
      const b = DpgsqlBox(DpgsqlPoint(10, 10), DpgsqlPoint(0, 0));
      final bytes = handler.write(b);
      expect(bytes.length, 32);
      final read = handler.read(bytes);
      expect(read.upperRight, b.upperRight);
      expect(read.lowerLeft, b.lowerLeft);
    });

    test('PathHandler', () {
      const handler = PathHandler();
      const p = DpgsqlPath([DpgsqlPoint(0, 0), DpgsqlPoint(1, 1)], open: true);
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
      const r = DpgsqlRange(lowerBound: 1, upperBound: 10);
      final bytes = handler.write(r);
      // Flags(1) + Len(4)+Val(4) + Len(4)+Val(4) = 1 + 8 + 8 = 17 bytes
      expect(bytes.length, 17);
      final read = handler.read(bytes);
      expect(read, r);
    });

    test('Int4RangeHandler Empty', () {
      final handler = RangeHandler<int>(0, const IntegerHandler());
      const r = DpgsqlRange<int>.empty();
      final bytes = handler.write(r);
      expect(bytes.length, 1);
      expect(bytes[0], 0x01); // Empty flag
      final read = handler.read(bytes);
      expect(read.isEmpty, true);
    });

    test('Int4RangeHandler Infinite', () {
      final handler = RangeHandler<int>(0, const IntegerHandler());
      const r = DpgsqlRange<int>(lowerBoundInfinite: true, upperBound: 5);
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

  group('Text Array Parsing', () {
    test('Int Array', () {
      final handler = ArrayHandler<int>(0, const IntegerHandler());
      final text = '{1,2,3}';
      final bytes = utf8.encode(text);
      final result = handler.read(Uint8List.fromList(bytes), isText: true);
      expect(result, [1, 2, 3]);
    });

    test('Int Array with NULL', () {
      final handler = ArrayHandler<int?>(0, const IntegerHandler());
      final text = '{1,NULL,3}';
      final bytes = utf8.encode(text);
      final result = handler.read(Uint8List.fromList(bytes), isText: true);
      expect(result, [1, null, 3]);
    });

    test('String Array', () {
      final handler = ArrayHandler<String>(0, const TextHandler());
      final text = '{"abc","def"}';
      final bytes = utf8.encode(text);
      final result = handler.read(Uint8List.fromList(bytes), isText: true);
      expect(result, ['abc', 'def']);
    });

    test('String Array with Escapes', () {
      final handler = ArrayHandler<String>(0, const TextHandler());
      // "a,b", "c\"d"
      final text = '{"a,b","c\\"d"}';
      final bytes = utf8.encode(text);
      final result = handler.read(Uint8List.fromList(bytes), isText: true);
      expect(result, ['a,b', 'c"d']);
    });

    test('Nested Int Array', () {
      final handler = ArrayHandler<dynamic>(0, const IntegerHandler());
      final text = '{{1,2},{3,4}}';
      final bytes = utf8.encode(text);
      final result = handler.read(Uint8List.fromList(bytes), isText: true);
      expect(result, [
        [1, 2],
        [3, 4]
      ]);
    });
  });

  group('DpgsqlInterval Parsing', () {
    test('Parse full format', () {
      final i = DpgsqlInterval.parse('1 year 2 mons 3 days 04:05:06.5');
      // 1 year = 12 months. Total months = 14.
      expect(i.months, 14);
      expect(i.days, 3);
      // 04:05:06.5 -> 4h + 5m + 6.5s
      // 4*3600 + 5*60 + 6.5 = 14400 + 300 + 6.5 = 14706.5 seconds
      // 14706.5 * 1000000 = 14706500000 microseconds
      expect(i.time, 14706500000);
    });

    test('Parse partial', () {
      final i = DpgsqlInterval.parse('1 day 01:00:00');
      expect(i.months, 0);
      expect(i.days, 1);
      expect(i.time, 3600000000);
    });

    test('Parse negative', () {
      final i = DpgsqlInterval.parse('-1 days');
      expect(i.days, -1);
    });

    test('Parse plurals and singulars', () {
      final i = DpgsqlInterval.parse('1 year 1 mon 1 day');
      expect(i.months, 13);
      expect(i.days, 1);
    });
  });

  group('DpgsqlDecimal', () {
    test('toString formats base-10000 digits', () {
      const value = DpgsqlDecimal(
        ndigits: 2,
        weight: 0,
        sign: 0,
        dscale: 2,
        digits: [123, 4500],
      );

      expect(value.toString(), '123.45');
    });

    test('toString formats negative fractional value', () {
      const value = DpgsqlDecimal(
        ndigits: 1,
        weight: -1,
        sign: 0x4000,
        dscale: 4,
        digits: [1250],
      );

      expect(value.toString(), '-0.1250');
    });

    test('parse converts text numeric to base-10000 digits', () {
      final value = DpgsqlDecimal.parse('123456.7800');

      expect(value.ndigits, 3);
      expect(value.weight, 1);
      expect(value.sign, 0);
      expect(value.dscale, 4);
      expect(value.digits, orderedEquals(<int>[12, 3456, 7800]));
      expect(value.toString(), '123456.7800');
    });

    test('parse converts negative fractional text numeric', () {
      final value = DpgsqlDecimal.parse('-0.00123');

      expect(value.weight, -1);
      expect(value.sign, 0x4000);
      expect(value.dscale, 5);
      expect(value.digits, orderedEquals(<int>[12, 3000]));
      expect(value.toString(), '-0.00123');
    });

    test('parse expands scientific notation', () {
      expect(DpgsqlDecimal.parse('1.23e3').toString(), '1230');
      expect(DpgsqlDecimal.parse('1.23e-3').toString(), '0.00123');
    });
  });
}
