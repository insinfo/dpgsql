import 'dart:typed_data';
import 'dart:convert';

import 'oid.dart';
import 'type_handler.dart';
import 'dpgsql_geometric.dart';

class PointHandler extends TypeHandler<DpgsqlPoint> {
  const PointHandler();

  @override
  int get oid => Oid.point;

  @override
  DpgsqlPoint read(Uint8List buffer,
      {bool isText = false, Encoding encoding = utf8}) {
    if (isText) {
      // (x,y)
      final str = encoding.decode(buffer);
      final parts = str.substring(1, str.length - 1).split(',');
      return DpgsqlPoint(double.parse(parts[0]), double.parse(parts[1]));
    }
    final bd = ByteData.sublistView(buffer);
    return DpgsqlPoint(bd.getFloat64(0), bd.getFloat64(8));
  }

  @override
  Uint8List write(DpgsqlPoint value, {Encoding encoding = utf8}) {
    final bd = ByteData(16);
    bd.setFloat64(0, value.x);
    bd.setFloat64(8, value.y);
    return bd.buffer.asUint8List();
  }
}

class BoxHandler extends TypeHandler<DpgsqlBox> {
  const BoxHandler();

  @override
  int get oid => Oid.box;

  @override
  DpgsqlBox read(Uint8List buffer,
      {bool isText = false, Encoding encoding = utf8}) {
    if (isText) {
      // (x1,y1),(x2,y2)
      final str = encoding.decode(buffer);
      // Remove outer parens? Box format: (x,y),(x,y)
      // Actually standard format in text is (x1,y1),(x2,y2) no outer parens wrapping both
      // Wait, let's assume it is (1,2),(3,4)
      final parts = str.split('),(');
      if (parts.length != 2) throw FormatException('Invalid Box format: $str');

      final p1Str = parts[0].replaceAll('(', '');
      final p2Str = parts[1].replaceAll(')', '');

      final p1Parts = p1Str.split(',');
      final p2Parts = p2Str.split(',');

      final p1 =
          DpgsqlPoint(double.parse(p1Parts[0]), double.parse(p1Parts[1]));
      final p2 =
          DpgsqlPoint(double.parse(p2Parts[0]), double.parse(p2Parts[1]));
      return DpgsqlBox(p1, p2);
    }
    final bd = ByteData.sublistView(buffer);
    final high = DpgsqlPoint(bd.getFloat64(0), bd.getFloat64(8));
    final low = DpgsqlPoint(bd.getFloat64(16), bd.getFloat64(24));
    return DpgsqlBox(high, low);
  }

  @override
  Uint8List write(DpgsqlBox value, {Encoding encoding = utf8}) {
    final bd = ByteData(32);
    bd.setFloat64(0, value.upperRight.x);
    bd.setFloat64(8, value.upperRight.y);
    bd.setFloat64(16, value.lowerLeft.x);
    bd.setFloat64(24, value.lowerLeft.y);
    return bd.buffer.asUint8List();
  }
}

class LSegHandler extends TypeHandler<DpgsqlLSeg> {
  const LSegHandler();

  @override
  int get oid => Oid.lseg;

  @override
  DpgsqlLSeg read(Uint8List buffer,
      {bool isText = false, Encoding encoding = utf8}) {
    if (isText) {
      // [(x1,y1),(x2,y2)]
      final str = encoding.decode(buffer);
      final clean = str.substring(1, str.length - 1); // remove [ ]
      final parts = clean.split('),(');
      if (parts.length != 2) throw FormatException('Invalid LSeg format: $str');

      final p1Str = parts[0].replaceAll('(', '');
      final p2Str = parts[1].replaceAll(')', '');

      final p1Parts = p1Str.split(',');
      final p2Parts = p2Str.split(',');

      final p1 =
          DpgsqlPoint(double.parse(p1Parts[0]), double.parse(p1Parts[1]));
      final p2 =
          DpgsqlPoint(double.parse(p2Parts[0]), double.parse(p2Parts[1]));
      return DpgsqlLSeg(p1, p2);
    }
    final bd = ByteData.sublistView(buffer);
    final start = DpgsqlPoint(bd.getFloat64(0), bd.getFloat64(8));
    final end = DpgsqlPoint(bd.getFloat64(16), bd.getFloat64(24));
    return DpgsqlLSeg(start, end);
  }

  @override
  Uint8List write(DpgsqlLSeg value, {Encoding encoding = utf8}) {
    final bd = ByteData(32);
    bd.setFloat64(0, value.start.x);
    bd.setFloat64(8, value.start.y);
    bd.setFloat64(16, value.end.x);
    bd.setFloat64(24, value.end.y);
    return bd.buffer.asUint8List();
  }
}

class LineHandler extends TypeHandler<DpgsqlLine> {
  const LineHandler();

  @override
  int get oid => Oid.line;

  @override
  DpgsqlLine read(Uint8List buffer,
      {bool isText = false, Encoding encoding = utf8}) {
    if (isText) {
      // {a,b,c}
      final str = encoding.decode(buffer);
      final clean = str.substring(1, str.length - 1);
      final parts = clean.split(',');
      return DpgsqlLine(double.parse(parts[0]), double.parse(parts[1]),
          double.parse(parts[2]));
    }
    final bd = ByteData.sublistView(buffer);
    return DpgsqlLine(bd.getFloat64(0), bd.getFloat64(8), bd.getFloat64(16));
  }

  @override
  Uint8List write(DpgsqlLine value, {Encoding encoding = utf8}) {
    final bd = ByteData(24);
    bd.setFloat64(0, value.a);
    bd.setFloat64(8, value.b);
    bd.setFloat64(16, value.c);
    return bd.buffer.asUint8List();
  }
}

class PathHandler extends TypeHandler<DpgsqlPath> {
  const PathHandler();

  @override
  int get oid => Oid.path;

  @override
  DpgsqlPath read(Uint8List buffer,
      {bool isText = false, Encoding encoding = utf8}) {
    if (isText) {
      // [(x,y),...] or ((x,y),...)
      final str = encoding.decode(buffer);
      final open = str.startsWith('[');
      final clean = str.substring(1, str.length - 1);
      final pointStrs = clean.split('),(');
      final points = <DpgsqlPoint>[];
      for (var s in pointStrs) {
        s = s.replaceAll('(', '').replaceAll(')', '');
        final parts = s.split(',');
        points.add(DpgsqlPoint(double.parse(parts[0]), double.parse(parts[1])));
      }
      return DpgsqlPath(points, open: open);
    }
    final bd = ByteData.sublistView(buffer);
    // Postgres docs: "1 byte for boolean (0=closed, 1=open)"
    final open = buffer[0] == 1;

    final npts = bd.getInt32(1);
    final points = <DpgsqlPoint>[];
    int offset = 5;
    for (var i = 0; i < npts; i++) {
      points.add(DpgsqlPoint(bd.getFloat64(offset), bd.getFloat64(offset + 8)));
      offset += 16;
    }
    return DpgsqlPath(points, open: open);
  }

  @override
  Uint8List write(DpgsqlPath value, {Encoding encoding = utf8}) {
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

class PolygonHandler extends TypeHandler<DpgsqlPolygon> {
  const PolygonHandler();

  @override
  int get oid => Oid.polygon;

  @override
  DpgsqlPolygon read(Uint8List buffer,
      {bool isText = false, Encoding encoding = utf8}) {
    if (isText) {
      // ((x,y),...)
      final str = encoding.decode(buffer);
      final clean = str.substring(1, str.length - 1); // remove outer ( )
      // The Inner part is (x,y),(x,y)...
      final inner =
          clean.startsWith('(') ? clean.substring(1, clean.length - 1) : clean;
      final pointStrs = inner.split('),(');
      final points = <DpgsqlPoint>[];
      for (var s in pointStrs) {
        s = s.replaceAll('(', '').replaceAll(')', '');
        final parts = s.split(',');
        points.add(DpgsqlPoint(double.parse(parts[0]), double.parse(parts[1])));
      }
      return DpgsqlPolygon(points);
    }
    final bd = ByteData.sublistView(buffer);
    final npts = bd.getInt32(0);
    final points = <DpgsqlPoint>[];
    int offset = 4;
    for (var i = 0; i < npts; i++) {
      points.add(DpgsqlPoint(bd.getFloat64(offset), bd.getFloat64(offset + 8)));
      offset += 16;
    }
    return DpgsqlPolygon(points);
  }

  @override
  Uint8List write(DpgsqlPolygon value, {Encoding encoding = utf8}) {
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

class CircleHandler extends TypeHandler<DpgsqlCircle> {
  const CircleHandler();

  @override
  int get oid => Oid.circle;

  @override
  DpgsqlCircle read(Uint8List buffer,
      {bool isText = false, Encoding encoding = utf8}) {
    if (isText) {
      // <(x,y),r>
      final str = encoding.decode(buffer);
      final clean = str.substring(1, str.length - 1); // remove < >
      final commaIndex = clean.lastIndexOf(',');
      final pointStr = clean.substring(0, commaIndex);
      final rStr = clean.substring(commaIndex + 1);

      final pStrClean =
          pointStr.substring(1, pointStr.length - 1); // remove ( )
      final pParts = pStrClean.split(',');

      final center =
          DpgsqlPoint(double.parse(pParts[0]), double.parse(pParts[1]));
      final radius = double.parse(rStr);
      return DpgsqlCircle(center, radius);
    }
    final bd = ByteData.sublistView(buffer);
    final center = DpgsqlPoint(bd.getFloat64(0), bd.getFloat64(8));
    final radius = bd.getFloat64(16);
    return DpgsqlCircle(center, radius);
  }

  @override
  Uint8List write(DpgsqlCircle value, {Encoding encoding = utf8}) {
    final bd = ByteData(24);
    bd.setFloat64(0, value.center.x);
    bd.setFloat64(8, value.center.y);
    bd.setFloat64(16, value.radius);
    return bd.buffer.asUint8List();
  }
}
