import 'dart:typed_data';
import 'dart:convert';

import 'oid.dart';
import 'type_handler.dart';
import 'npgsql_geometric.dart';

class PointHandler extends TypeHandler<NpgsqlPoint> {
  const PointHandler();

  @override
  int get oid => Oid.point;

  @override
  NpgsqlPoint read(Uint8List buffer, {bool isText = false}) {
    if (isText) {
      // (x,y)
      final str = utf8.decode(buffer);
      final parts = str.substring(1, str.length - 1).split(',');
      return NpgsqlPoint(double.parse(parts[0]), double.parse(parts[1]));
    }
    final bd = ByteData.sublistView(buffer);
    return NpgsqlPoint(bd.getFloat64(0), bd.getFloat64(8));
  }

  @override
  Uint8List write(NpgsqlPoint value) {
    final bd = ByteData(16);
    bd.setFloat64(0, value.x);
    bd.setFloat64(8, value.y);
    return bd.buffer.asUint8List();
  }
}

class BoxHandler extends TypeHandler<NpgsqlBox> {
  const BoxHandler();

  @override
  int get oid => Oid.box;

  @override
  NpgsqlBox read(Uint8List buffer, {bool isText = false}) {
    if (isText) {
      // (x1,y1),(x2,y2)
      // Parsing text geometric types is complex due to nested parens
      // For now, simple split might fail if numbers have commas (unlikely for standard float format)
      // But standard format is (x,y),(x,y)
      // TODO: Robust text parsing
      throw UnimplementedError('Text parsing for Box not fully implemented');
    }
    final bd = ByteData.sublistView(buffer);
    final high = NpgsqlPoint(bd.getFloat64(0), bd.getFloat64(8));
    final low = NpgsqlPoint(bd.getFloat64(16), bd.getFloat64(24));
    return NpgsqlBox(high, low);
  }

  @override
  Uint8List write(NpgsqlBox value) {
    final bd = ByteData(32);
    bd.setFloat64(0, value.upperRight.x);
    bd.setFloat64(8, value.upperRight.y);
    bd.setFloat64(16, value.lowerLeft.x);
    bd.setFloat64(24, value.lowerLeft.y);
    return bd.buffer.asUint8List();
  }
}

class LSegHandler extends TypeHandler<NpgsqlLSeg> {
  const LSegHandler();

  @override
  int get oid => Oid.lseg;

  @override
  NpgsqlLSeg read(Uint8List buffer, {bool isText = false}) {
    if (isText)
      throw UnimplementedError('Text parsing for LSeg not implemented');
    final bd = ByteData.sublistView(buffer);
    final start = NpgsqlPoint(bd.getFloat64(0), bd.getFloat64(8));
    final end = NpgsqlPoint(bd.getFloat64(16), bd.getFloat64(24));
    return NpgsqlLSeg(start, end);
  }

  @override
  Uint8List write(NpgsqlLSeg value) {
    final bd = ByteData(32);
    bd.setFloat64(0, value.start.x);
    bd.setFloat64(8, value.start.y);
    bd.setFloat64(16, value.end.x);
    bd.setFloat64(24, value.end.y);
    return bd.buffer.asUint8List();
  }
}

class LineHandler extends TypeHandler<NpgsqlLine> {
  const LineHandler();

  @override
  int get oid => Oid.line;

  @override
  NpgsqlLine read(Uint8List buffer, {bool isText = false}) {
    if (isText)
      throw UnimplementedError('Text parsing for Line not implemented');
    final bd = ByteData.sublistView(buffer);
    return NpgsqlLine(bd.getFloat64(0), bd.getFloat64(8), bd.getFloat64(16));
  }

  @override
  Uint8List write(NpgsqlLine value) {
    final bd = ByteData(24);
    bd.setFloat64(0, value.a);
    bd.setFloat64(8, value.b);
    bd.setFloat64(16, value.c);
    return bd.buffer.asUint8List();
  }
}

class PathHandler extends TypeHandler<NpgsqlPath> {
  const PathHandler();

  @override
  int get oid => Oid.path;

  @override
  NpgsqlPath read(Uint8List buffer, {bool isText = false}) {
    if (isText)
      throw UnimplementedError('Text parsing for Path not implemented');
    final bd = ByteData.sublistView(buffer);
    // Postgres docs: "1 byte for boolean (0=closed, 1=open)"
    final open = buffer[0] == 1;

    final npts = bd.getInt32(1);
    final points = <NpgsqlPoint>[];
    int offset = 5;
    for (var i = 0; i < npts; i++) {
      points.add(NpgsqlPoint(bd.getFloat64(offset), bd.getFloat64(offset + 8)));
      offset += 16;
    }
    return NpgsqlPath(points, open: open);
  }

  @override
  Uint8List write(NpgsqlPath value) {
    final bd = ByteData(5 + value.points.length * 16);
    bd.setUint8(0, value.open ? 1 : 0);
    bd.setInt32(1, value.points.length);
    int offset = 5;
    for (final p in value.points) {
      bd.setFloat64(offset, p.x);
      bd.setFloat64(offset + 8, p.y);
      offset += 16;
    }
    return bd.buffer.asUint8List();
  }
}

class PolygonHandler extends TypeHandler<NpgsqlPolygon> {
  const PolygonHandler();

  @override
  int get oid => Oid.polygon;

  @override
  NpgsqlPolygon read(Uint8List buffer, {bool isText = false}) {
    if (isText)
      throw UnimplementedError('Text parsing for Polygon not implemented');
    final bd = ByteData.sublistView(buffer);
    final npts = bd.getInt32(0);
    final points = <NpgsqlPoint>[];
    int offset = 4;
    for (var i = 0; i < npts; i++) {
      points.add(NpgsqlPoint(bd.getFloat64(offset), bd.getFloat64(offset + 8)));
      offset += 16;
    }
    return NpgsqlPolygon(points);
  }

  @override
  Uint8List write(NpgsqlPolygon value) {
    final bd = ByteData(4 + value.points.length * 16);
    bd.setInt32(0, value.points.length);
    int offset = 4;
    for (final p in value.points) {
      bd.setFloat64(offset, p.x);
      bd.setFloat64(offset + 8, p.y);
      offset += 16;
    }
    return bd.buffer.asUint8List();
  }
}

class CircleHandler extends TypeHandler<NpgsqlCircle> {
  const CircleHandler();

  @override
  int get oid => Oid.circle;

  @override
  NpgsqlCircle read(Uint8List buffer, {bool isText = false}) {
    if (isText)
      throw UnimplementedError('Text parsing for Circle not implemented');
    final bd = ByteData.sublistView(buffer);
    final center = NpgsqlPoint(bd.getFloat64(0), bd.getFloat64(8));
    final radius = bd.getFloat64(16);
    return NpgsqlCircle(center, radius);
  }

  @override
  Uint8List write(NpgsqlCircle value) {
    final bd = ByteData(24);
    bd.setFloat64(0, value.center.x);
    bd.setFloat64(8, value.center.y);
    bd.setFloat64(16, value.radius);
    return bd.buffer.asUint8List();
  }
}
