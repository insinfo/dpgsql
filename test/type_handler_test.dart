import 'dart:typed_data';
import 'package:dpgsql/src/types/type_handler.dart';
import 'package:dpgsql/src/types/oid.dart';
import 'package:test/test.dart';

void main() {
  group('ArrayHandler', () {
    final intHandler = IntegerHandler();
    // Use ArrayHandler<int?> for null tests
    final arrayHandlerNullable = ArrayHandler<int?>(Oid.int4Array, intHandler);
    // Use ArrayHandler<dynamic> for 2D tests
    final arrayHandlerDynamic =
        ArrayHandler<dynamic>(Oid.int4Array, intHandler);

    test('Reads 1D array', () {
      // {1, 2}
      final buffer = _createArrayBuffer(
        ndim: 1,
        elementOid: Oid.int4,
        dims: [2],
        values: [1, 2],
      );
      final result = arrayHandlerNullable.read(buffer);
      expect(result, equals([1, 2]));
    });

    test('Reads 2D array (nested)', () {
      // {{1, 2}, {3, 4}}
      final buffer = _createArrayBuffer(
        ndim: 2,
        elementOid: Oid.int4,
        dims: [2, 2],
        values: [1, 2, 3, 4],
      );
      // Should return nested list
      final result = arrayHandlerDynamic.read(buffer);
      expect(
          result,
          equals([
            [1, 2],
            [3, 4]
          ]));
    });

    test('Reads array with null', () {
      // {1, NULL}
      final buffer = _createArrayBuffer(
        ndim: 1,
        elementOid: Oid.int4,
        dims: [2],
        values: [1, null],
      );

      final result = arrayHandlerNullable.read(buffer);
      expect(result, equals([1, null]));
    });

    test('Writes 1D array', () {
      final bytes = arrayHandlerNullable.write([1, 2]);
      // Verify bytes...
      expect(bytes.length, greaterThan(20));
    });

    test('Writes array with null', () {
      final bytes = arrayHandlerNullable.write([1, null]);
      expect(bytes.length, greaterThan(20));
    });

    test('Writes 2D array', () {
      final bytes = arrayHandlerDynamic.write([
        [1, 2],
        [3, 4]
      ]);
      expect(bytes.length, greaterThan(20));
      // Could verify content but length check is a start
    });
  });
}

Uint8List _createArrayBuffer({
  required int ndim,
  required int elementOid,
  required List<int> dims,
  required List<int?> values,
}) {
  final out = <int>[];
  final bd = ByteData(4);

  // Header
  bd.setInt32(0, ndim);
  out.addAll(bd.buffer.asUint8List());
  bd.setInt32(0, 0);
  out.addAll(bd.buffer.asUint8List()); // flags
  bd.setInt32(0, elementOid);
  out.addAll(bd.buffer.asUint8List());

  // Dims
  for (final d in dims) {
    bd.setInt32(0, d);
    out.addAll(bd.buffer.asUint8List());
    bd.setInt32(0, 1);
    out.addAll(bd.buffer.asUint8List()); // lbound
  }

  // Values
  for (final v in values) {
    if (v == null) {
      bd.setInt32(0, -1);
      out.addAll(bd.buffer.asUint8List());
    } else {
      bd.setInt32(0, 4);
      out.addAll(bd.buffer.asUint8List()); // len
      bd.setInt32(0, v);
      out.addAll(bd.buffer.asUint8List()); // value
    }
  }

  return Uint8List.fromList(out);
}
