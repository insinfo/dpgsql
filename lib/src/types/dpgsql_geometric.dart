/// Represents a PostgreSQL Point type.
class DpgsqlPoint {
  const DpgsqlPoint(this.x, this.y);

  final double x;
  final double y;

  @override
  String toString() => '($x,$y)';

  @override
  bool operator ==(Object other) =>
      other is DpgsqlPoint && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);
}

/// Represents a PostgreSQL Box type.
class DpgsqlBox {
  const DpgsqlBox(this.upperRight, this.lowerLeft);

  final DpgsqlPoint upperRight;
  final DpgsqlPoint lowerLeft;

  @override
  String toString() => '$upperRight,$lowerLeft';
}

/// Represents a PostgreSQL Line Segment type (lseg).
class DpgsqlLSeg {
  const DpgsqlLSeg(this.start, this.end);

  final DpgsqlPoint start;
  final DpgsqlPoint end;

  @override
  String toString() => '[$start,$end]';
}

/// Represents a PostgreSQL Line type.
/// Equation: Ax + By + C = 0
class DpgsqlLine {
  const DpgsqlLine(this.a, this.b, this.c);

  final double a;
  final double b;
  final double c;

  @override
  String toString() => '{$a,$b,$c}';
}

/// Represents a PostgreSQL Path type.
class DpgsqlPath {
  const DpgsqlPath(this.points, {this.open = false});

  final List<DpgsqlPoint> points;
  final bool open;

  @override
  String toString() =>
      '${open ? "[" : "("}${points.join(",")}${open ? "]" : ")"}';
}

/// Represents a PostgreSQL Polygon type.
class DpgsqlPolygon {
  const DpgsqlPolygon(this.points);

  final List<DpgsqlPoint> points;

  @override
  String toString() => '(${points.join(",")})';
}

/// Represents a PostgreSQL Circle type.
class DpgsqlCircle {
  const DpgsqlCircle(this.center, this.radius);

  final DpgsqlPoint center;
  final double radius;

  @override
  String toString() => '<$center,$radius>';
}
