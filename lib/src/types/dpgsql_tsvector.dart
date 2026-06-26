/// Represents a PostgreSQL tsvector.
/// A tsvector is a sorted list of distinct lexemes with optional position information.
/// Porting DpgsqlTsVector.cs
class DpgsqlTsVector {
  DpgsqlTsVector(List<Lexeme> lexemes, {bool noCheck = false}) {
    if (noCheck) {
      _lexemes = lexemes;
      return;
    }

    _lexemes = List.from(lexemes);
    if (_lexemes.isEmpty) return;

    // Sort lexemes by text
    _lexemes.sort((a, b) => a.text.compareTo(b.text));

    // Remove duplicates and merge positions
    var res = 0;
    var pos = 1;
    while (pos < _lexemes.length) {
      if (_lexemes[pos].text != _lexemes[res].text) {
        // Done with this lexeme
        _lexemes[res] = Lexeme(
          _lexemes[res].text,
          wordEntryPositions:
              Lexeme._uniquePos(_lexemes[res].wordEntryPositions),
        );
        res++;
        if (res != pos) {
          _lexemes[res] = _lexemes[pos];
        }
      } else {
        // Merge word position lists
        var positions = _lexemes[res].wordEntryPositions;
        if (positions != null) {
          final otherPositions = _lexemes[pos].wordEntryPositions;
          if (otherPositions != null) {
            positions.addAll(otherPositions);
          }
        } else {
          _lexemes[res] = _lexemes[pos];
        }
      }
      pos++;
    }

    // Last element
    _lexemes[res] = Lexeme(
      _lexemes[res].text,
      wordEntryPositions: Lexeme._uniquePos(_lexemes[res].wordEntryPositions),
    );
    if (res != pos - 1) {
      _lexemes.removeRange(res + 1, pos);
    }
  }

  late final List<Lexeme> _lexemes;

  /// Represents an empty tsvector.
  static final DpgsqlTsVector empty = DpgsqlTsVector([], noCheck: true);

  /// Returns the lexeme at a specific index.
  Lexeme operator [](int index) {
    if (index < 0 || index >= _lexemes.length) {
      throw ArgumentError.value(index, 'index', 'Index out of range');
    }
    return _lexemes[index];
  }

  /// Gets the number of lexemes.
  int get count => _lexemes.length;

  /// Returns an iterator over the lexemes.
  Iterator<Lexeme> get iterator => _lexemes.iterator;

  /// Gets a string representation in PostgreSQL's format.
  @override
  String toString() => _lexemes.join(' ');

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! DpgsqlTsVector) return false;
    if (_lexemes.length != other._lexemes.length) return false;
    for (int i = 0; i < _lexemes.length; i++) {
      if (_lexemes[i] != other._lexemes[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(_lexemes);
}

/// Represents a lexeme. A lexeme consists of a text string and optional word entry positions.
class Lexeme {
  Lexeme(this.text, {List<WordEntryPos>? wordEntryPositions})
      : wordEntryPositions =
            wordEntryPositions != null ? List.from(wordEntryPositions) : null;

  /// The text of the lexeme.
  final String text;

  /// Optional word entry positions.
  final List<WordEntryPos>? wordEntryPositions;

  /// Gets a word entry position.
  WordEntryPos operator [](int index) {
    if (index < 0 ||
        wordEntryPositions == null ||
        index >= wordEntryPositions!.length) {
      throw ArgumentError.value(index, 'index', 'Index out of range');
    }
    return wordEntryPositions![index];
  }

  /// Gets the number of word entry positions.
  int get count => wordEntryPositions?.length ?? 0;

  /// Creates a string representation in PostgreSQL's format.
  @override
  String toString() {
    final escaped = text.replaceAll(r'\', r'\\').replaceAll("'", "''");
    var str = "'$escaped'";
    if (count > 0) {
      str += ':${wordEntryPositions!.join(',')}';
    }
    return str;
  }

  static List<WordEntryPos>? _uniquePos(List<WordEntryPos>? list) {
    if (list == null) return null;

    bool needsProcessing = false;
    for (int i = 1; i < list.length; i++) {
      if (list[i - 1].pos >= list[i].pos) {
        needsProcessing = true;
        break;
      }
    }
    if (!needsProcessing) return list;

    final result = List<WordEntryPos>.from(list);
    result.sort((a, b) => a.pos.compareTo(b.pos));

    int a = 0;
    for (int b = 1; b < result.length; b++) {
      if (result[a].pos != result[b].pos) {
        a++;
        if (a != b) result[a] = result[b];
      } else if (result[b].weight.index > result[a].weight.index) {
        result[a] = result[b];
      }
    }
    if (a != result.length - 1) {
      result.removeRange(a + 1, result.length);
    }
    return result;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! Lexeme) return false;
    if (text != other.text) return false;
    if (wordEntryPositions == null) return other.wordEntryPositions == null;
    if (other.wordEntryPositions == null) return false;
    if (wordEntryPositions!.length != other.wordEntryPositions!.length)
      return false;
    for (int i = 0; i < wordEntryPositions!.length; i++) {
      if (wordEntryPositions![i] != other.wordEntryPositions![i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => text.hashCode;
}

/// Represents a word entry position and an optional weight.
class WordEntryPos {
  WordEntryPos(int pos, [Weight weight = Weight.d]) {
    if (pos == 0) {
      throw ArgumentError.value(
          pos, 'pos', 'Position cannot be 0. Valid range is 1-16383.');
    }
    // Cap at 16383 (2^14 - 1)
    if (pos > 16383) pos = 16383;
    _value = ((weight.index & 3) << 14) | (pos & 0x3FFF);
  }

  late final int _value;

  /// The weight is labeled from A to D. D is the default.
  Weight get weight => Weight.values[(_value >> 14) & 3];

  /// The position in the text (1-16383).
  int get pos => _value & 0x3FFF;

  @override
  String toString() {
    if (weight != Weight.d) {
      return '$pos${weight.name.toUpperCase()}';
    }
    return pos.toString();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! WordEntryPos) return false;
    return _value == other._value;
  }

  @override
  int get hashCode => _value.hashCode;
}

/// Weight labels for tsvector lexeme positions.
enum Weight {
  /// D, the default weight.
  d,

  /// C weight.
  c,

  /// B weight.
  b,

  /// A weight (highest).
  a,
}
