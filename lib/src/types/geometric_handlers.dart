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
  NpgsqlPoint read(Uint8List buffer,
      {bool isText = false, Encoding encoding = utf8}) {
    if (isText) {
      // (x,y)
      final str = encoding.decode(buffer);
      final parts = str.substring(1, str.length - 1).split(',');
      return NpgsqlPoint(double.parse(parts[0]), double.parse(parts[1]));
    }
    final bd = ByteData.sublistView(buffer);
    return NpgsqlPoint(bd.getFloat64(0), bd.getFloat64(8));
  }

  @override
  Uint8List write(NpgsqlPoint value, {Encoding encoding = utf8}) {
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
  NpgsqlBox read(Uint8List buffer,
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
          NpgsqlPoint(double.parse(p1Parts[0]), double.parse(p1Parts[1]));
      final p2 =
          NpgsqlPoint(double.parse(p2Parts[0]), double.parse(p2Parts[1]));
      return NpgsqlBox(p1, p2);
    }
    final bd = ByteData.sublistView(buffer);
    final high = NpgsqlPoint(bd.getFloat64(0), bd.getFloat64(8));
    final low = NpgsqlPoint(bd.getFloat64(16), bd.getFloat64(24));
    return NpgsqlBox(high, low);
  }

  @override
  Uint8List write(NpgsqlBox value, {Encoding encoding = utf8}) {
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
  NpgsqlLSeg read(Uint8List buffer,
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
          NpgsqlPoint(double.parse(p1Parts[0]), double.parse(p1Parts[1]));
      final p2 =
          NpgsqlPoint(double.parse(p2Parts[0]), double.parse(p2Parts[1]));
      return NpgsqlLSeg(p1, p2);
    }
    final bd = ByteData.sublistView(buffer);
    final start = NpgsqlPoint(bd.getFloat64(0), bd.getFloat64(8));
    final end = NpgsqlPoint(bd.getFloat64(16), bd.getFloat64(24));
    return NpgsqlLSeg(start, end);
  }

  @override
  Uint8List write(NpgsqlLSeg value, {Encoding encoding = utf8}) {
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
  NpgsqlLine read(Uint8List buffer,
      {bool isText = false, Encoding encoding = utf8}) {
    if (isText) {
      // {a,b,c}
      final str = encoding.decode(buffer);
      final clean = str.substring(1, str.length - 1);
      final parts = clean.split(',');
      return NpgsqlLine(double.parse(parts[0]), double.parse(parts[1]),
          double.parse(parts[2]));
    }
    final bd = ByteData.sublistView(buffer);
    return NpgsqlLine(bd.getFloat64(0), bd.getFloat64(8), bd.getFloat64(16));
  }

  @override
  Uint8List write(NpgsqlLine value, {Encoding encoding = utf8}) {
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
  NpgsqlPath read(Uint8List buffer,
      {bool isText = false, Encoding encoding = utf8}) {
    if (isText) {
      // [(x,y),...] or ((x,y),...)
      final str = encoding.decode(buffer);
      final open = str.startsWith('[');
      final clean = str.substring(1, str.length - 1);
      final pointStrs = clean.split('),(');
      final points = <NpgsqlPoint>[];
      for (var s in pointStrs) {
        s = s.replaceAll('(', '').replaceAll(')', '');
        final parts = s.split(',');
        points.add(NpgsqlPoint(double.parse(parts[0]), double.parse(parts[1])));
      }
      return NpgsqlPath(points, open: open);
    }
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
  Uint8List write(NpgsqlPath value, {Encoding encoding = utf8}) {
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
  NpgsqlPolygon read(Uint8List buffer,
      {bool isText = false, Encoding encoding = utf8}) {
    if (isText) {
      // ((x,y),...)
      final str = encoding.decode(buffer);
      final clean = str.substring(1, str.length - 1); // remove outer ( )
      // The Inner part is (x,y),(x,y)...
      final inner =
          clean.startsWith('(') ? clean.substring(1, clean.length - 1) : clean;
      final pointStrs = inner.split('),(');
      final points = <NpgsqlPoint>[];
      for (var s in pointStrs) {
        s = s.replaceAll('(', '').replaceAll(')', '');
        final parts = s.split(',');
        points.add(NpgsqlPoint(double.parse(parts[0]), double.parse(parts[1])));
      }
      return NpgsqlPolygon(points);
    }
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
  Uint8List write(NpgsqlPolygon value, {Encoding encoding = utf8}) {
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
  NpgsqlCircle read(Uint8List buffer,
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
          NpgsqlPoint(double.parse(pParts[0]), double.parse(pParts[1]));
      final radius = double.parse(rStr);
      return NpgsqlCircle(center, radius);
    }
    final bd = ByteData.sublistView(buffer);
    final center = NpgsqlPoint(bd.getFloat64(0), bd.getFloat64(8));
    final radius = bd.getFloat64(16);
    return NpgsqlCircle(center, radius);
  }

  @override
  Uint8List write(NpgsqlCircle value, {Encoding encoding = utf8}) {
    final bd = ByteData(24);
    bd.setFloat64(0, value.center.x);
    bd.setFloat64(8, value.center.y);
    bd.setFloat64(16, value.radius);
    return bd.buffer.asUint8List();
  }
}
