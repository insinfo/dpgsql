/// Represents a PostgreSQL Range type.
class NpgsqlRange<T> {
  const NpgsqlRange({
    this.lowerBound,
    this.upperBound,
    this.lowerBoundInclusive = true,
    this.upperBoundInclusive = false,
    this.lowerBoundInfinite = false,
    this.upperBoundInfinite = false,
    this.isEmpty = false,
  });

  /// Creates an empty range.
  const NpgsqlRange.empty()
      : lowerBound = null,
        upperBound = null,
        lowerBoundInclusive = false,
        upperBoundInclusive = false,
        lowerBoundInfinite = false,
        upperBoundInfinite = false,
        isEmpty = true;

  final T? lowerBound;
  final T? upperBound;
  final bool lowerBoundInclusive;
  final bool upperBoundInclusive;
  final bool lowerBoundInfinite;
  final bool upperBoundInfinite;
  final bool isEmpty;

  @override
  String toString() {
    if (isEmpty) return 'empty';
    final sb = StringBuffer();
    sb.write(lowerBoundInclusive ? '[' : '(');
    if (lowerBoundInfinite) {
      sb.write('-infinity'); // Or just omit? Postgres format usually omits.
    } else {
      sb.write(lowerBound);
    }
    sb.write(',');
    if (upperBoundInfinite) {
      sb.write('infinity');
    } else {
      sb.write(upperBound);
    }
    sb.write(upperBoundInclusive ? ']' : ')');
    return sb.toString();
  }

  @override
  bool operator ==(Object other) =>
      other is NpgsqlRange<T> &&
      other.isEmpty == isEmpty &&
      (isEmpty ||
          (other.lowerBound == lowerBound &&
              other.upperBound == upperBound &&
              other.lowerBoundInclusive == lowerBoundInclusive &&
              other.upperBoundInclusive == upperBoundInclusive &&
              other.lowerBoundInfinite == lowerBoundInfinite &&
              other.upperBoundInfinite == upperBoundInfinite));

  @override
  int get hashCode => Object.hash(lowerBound, upperBound, lowerBoundInclusive,
      upperBoundInclusive, lowerBoundInfinite, upperBoundInfinite, isEmpty);
}
