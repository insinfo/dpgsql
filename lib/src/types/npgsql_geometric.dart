/// Represents a PostgreSQL Point type.
class NpgsqlPoint {
  const NpgsqlPoint(this.x, this.y);

  final double x;
  final double y;

  @override
  String toString() => '($x,$y)';

  @override
  bool operator ==(Object other) =>
      other is NpgsqlPoint && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);
}

/// Represents a PostgreSQL Box type.
class NpgsqlBox {
  const NpgsqlBox(this.upperRight, this.lowerLeft);

  final NpgsqlPoint upperRight;
  final NpgsqlPoint lowerLeft;

  @override
  String toString() => '$upperRight,$lowerLeft';
}

/// Represents a PostgreSQL Line Segment type (lseg).
class NpgsqlLSeg {
  const NpgsqlLSeg(this.start, this.end);

  final NpgsqlPoint start;
  final NpgsqlPoint end;

  @override
  String toString() => '[$start,$end]';
}

/// Represents a PostgreSQL Line type.
/// Equation: Ax + By + C = 0
class NpgsqlLine {
  const NpgsqlLine(this.a, this.b, this.c);

  final double a;
  final double b;
  final double c;

  @override
  String toString() => '{$a,$b,$c}';
}

/// Represents a PostgreSQL Path type.
class NpgsqlPath {
  const NpgsqlPath(this.points, {this.open = false});

  final List<NpgsqlPoint> points;
  final bool open;

  @override
  String toString() =>
      '${open ? "[" : "("}${points.join(",")}${open ? "]" : ")"}';
}

/// Represents a PostgreSQL Polygon type.
class NpgsqlPolygon {
  const NpgsqlPolygon(this.points);

  final List<NpgsqlPoint> points;

  @override
  String toString() => '(${points.join(",")})';
}

/// Represents a PostgreSQL Circle type.
class NpgsqlCircle {
  const NpgsqlCircle(this.center, this.radius);

  final NpgsqlPoint center;
  final double radius;

  @override
  String toString() => '<$center,$radius>';
}
