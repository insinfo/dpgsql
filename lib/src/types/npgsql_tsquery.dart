/// Represents a PostgreSQL tsquery. This is the base class for the
/// lexeme, not, or, and, and "followed by" nodes.
/// Porting NpgsqlTsQuery.cs
abstract class NpgsqlTsQuery {
  NpgsqlTsQuery(this.kind);

  /// Node kind.
  final TsQueryNodeKind kind;

  /// Writes the tsquery in PostgreSQL's text format.
  void write(StringBuffer sb, {bool first = false});

  @override
  String toString() {
    final sb = StringBuffer();
    write(sb, first: true);
    return sb.toString();
  }

  @override
  bool operator ==(Object other);

  @override
  int get hashCode;
}

/// Node kind for tsquery.
enum TsQueryNodeKind {
  /// Represents the empty tsquery. Should only be used at top level.
  empty,

  /// Lexeme
  lexeme,

  /// Not operator
  not,

  /// And operator
  and,

  /// Or operator
  or,

  /// "Followed by" operator
  phrase,
}

/// TsQuery Lexeme node.
class NpgsqlTsQueryLexeme extends NpgsqlTsQuery {
  NpgsqlTsQueryLexeme(
    this.text, {
    this.weights = TsQueryWeight.none,
    this.isPrefixSearch = false,
  }) : super(TsQueryNodeKind.lexeme);

  /// Lexeme text.
  String text;

  /// Weights is a bitmask of the TsQueryWeight enum.
  TsQueryWeight weights;

  /// Prefix search.
  bool isPrefixSearch;

  @override
  void write(StringBuffer sb, {bool first = false}) {
    final escaped = text.replaceAll(r'\', r'\\').replaceAll("'", "''");
    sb.write("'$escaped'");
    if (isPrefixSearch || weights != TsQueryWeight.none) {
      sb.write(':');
    }
    if (isPrefixSearch) {
      sb.write('*');
    }
    if (weights.hasA) sb.write('A');
    if (weights.hasB) sb.write('B');
    if (weights.hasC) sb.write('C');
    if (weights.hasD) sb.write('D');
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! NpgsqlTsQueryLexeme) return false;
    return other.text == text &&
        other.weights == weights &&
        other.isPrefixSearch == isPrefixSearch;
  }

  @override
  int get hashCode => Object.hash(text, weights, isPrefixSearch);
}

/// Weight enum for tsquery lexeme, can be OR'ed together.
class TsQueryWeight {
  const TsQueryWeight._(this._value);

  final int _value;

  static const TsQueryWeight none = TsQueryWeight._(0);
  static const TsQueryWeight d = TsQueryWeight._(1);
  static const TsQueryWeight c = TsQueryWeight._(2);
  static const TsQueryWeight b = TsQueryWeight._(4);
  static const TsQueryWeight a = TsQueryWeight._(8);

  bool get hasD => (_value & 1) != 0;
  bool get hasC => (_value & 2) != 0;
  bool get hasB => (_value & 4) != 0;
  bool get hasA => (_value & 8) != 0;

  TsQueryWeight operator |(TsQueryWeight other) =>
      TsQueryWeight._(_value | other._value);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! TsQueryWeight) return false;
    return _value == other._value;
  }

  @override
  int get hashCode => _value.hashCode;
}

/// TsQuery Not node.
class NpgsqlTsQueryNot extends NpgsqlTsQuery {
  NpgsqlTsQueryNot(this.child) : super(TsQueryNodeKind.not);

  /// Child node.
  NpgsqlTsQuery child;

  @override
  void write(StringBuffer sb, {bool first = false}) {
    sb.write('!');
    if (child.kind != TsQueryNodeKind.lexeme) {
      sb.write('( ');
    }
    child.write(sb, first: true);
    if (child.kind != TsQueryNodeKind.lexeme) {
      sb.write(' )');
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! NpgsqlTsQueryNot) return false;
    return other.child == child;
  }

  @override
  int get hashCode => child.hashCode;
}

/// Base class for TsQuery binary operators (& and |).
abstract class NpgsqlTsQueryBinOp extends NpgsqlTsQuery {
  NpgsqlTsQueryBinOp(super.kind, this.left, this.right);

  /// Left child.
  NpgsqlTsQuery left;

  /// Right child.
  NpgsqlTsQuery right;
}

/// TsQuery And node.
class NpgsqlTsQueryAnd extends NpgsqlTsQueryBinOp {
  NpgsqlTsQueryAnd(NpgsqlTsQuery left, NpgsqlTsQuery right)
      : super(TsQueryNodeKind.and, left, right);

  @override
  void write(StringBuffer sb, {bool first = false}) {
    left.write(sb);
    sb.write(' & ');
    right.write(sb);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! NpgsqlTsQueryAnd) return false;
    return other.left == left && other.right == right;
  }

  @override
  int get hashCode => Object.hash(left, right);
}

/// TsQuery Or Node.
class NpgsqlTsQueryOr extends NpgsqlTsQueryBinOp {
  NpgsqlTsQueryOr(NpgsqlTsQuery left, NpgsqlTsQuery right)
      : super(TsQueryNodeKind.or, left, right);

  @override
  void write(StringBuffer sb, {bool first = false}) {
    if (!first) sb.write('( ');
    left.write(sb);
    sb.write(' | ');
    right.write(sb);
    if (!first) sb.write(' )');
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! NpgsqlTsQueryOr) return false;
    return other.left == left && other.right == right;
  }

  @override
  int get hashCode => Object.hash(left, right);
}

/// TsQuery "Followed by" Node.
class NpgsqlTsQueryFollowedBy extends NpgsqlTsQueryBinOp {
  NpgsqlTsQueryFollowedBy(
      NpgsqlTsQuery left, this.distance, NpgsqlTsQuery right)
      : super(TsQueryNodeKind.phrase, left, right) {
    if (distance < 0) {
      throw ArgumentError.value(
          distance, 'distance', 'Distance must be non-negative');
    }
  }

  /// The distance between the 2 nodes, in lexemes.
  int distance;

  @override
  void write(StringBuffer sb, {bool first = false}) {
    if (!first) sb.write('( ');
    left.write(sb);
    sb.write(' <');
    if (distance == 1) {
      sb.write('-');
    } else {
      sb.write(distance);
    }
    sb.write('> ');
    right.write(sb);
    if (!first) sb.write(' )');
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! NpgsqlTsQueryFollowedBy) return false;
    return other.left == left &&
        other.right == right &&
        other.distance == distance;
  }

  @override
  int get hashCode => Object.hash(left, right, distance);
}

/// Represents an empty tsquery. Should only be used as top node.
class NpgsqlTsQueryEmpty extends NpgsqlTsQuery {
  NpgsqlTsQueryEmpty() : super(TsQueryNodeKind.empty);

  @override
  void write(StringBuffer sb, {bool first = false}) {
    // Empty - writes nothing
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is NpgsqlTsQueryEmpty;
  }

  @override
  int get hashCode => kind.hashCode;
}
