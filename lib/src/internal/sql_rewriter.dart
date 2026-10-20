import '../dpgsql_parameter_collection.dart';
import '../dpgsql_parameter.dart';

class RewrittenSql {
  final String sql;
  final List<DpgsqlParameter> orderedParameters;

  RewrittenSql(this.sql, this.orderedParameters);
}

/// Rewrites `@name` and `?` placeholders as `$1, $2, ...`.
///
/// Text that cannot hold a placeholder is copied unchanged: string literals
/// (`'...'`, `E'...'` with backslash escapes), quoted identifiers, dollar
/// quoted strings (`$$...$$`, `$tag$...$tag$`), line comments (`-- ...`) and
/// block comments (`/* ... */`, nested as in PostgreSQL). Comments used to be
/// scanned like SQL: an apostrophe in a comment opened a string and shifted
/// every placeholder after it.
class SqlRewriter {
  static RewrittenSql rewrite(
      String sql, DpgsqlParameterCollection parameters) {
    if (parameters.isEmpty) {
      return RewrittenSql(sql, []);
    }

    final sb = StringBuffer();
    final orderedParams = <DpgsqlParameter>[];
    final paramIndexMap = <String, int>{}; // Name -> Index (1-based)

    int index = 0;
    int positionalIndex = 0; // For ? placeholders
    var sawNumberedPlaceholder = false; // $1, $2, ... written by hand
    final len = sql.length;

    /// Copies [sql] from [index] up to [end] (exclusive) and moves there.
    void copyTo(int end) {
      sb.write(sql.substring(index, end));
      index = end;
    }

    while (index < len) {
      final char = sql[index];
      final next = index + 1 < len ? sql[index + 1] : '';

      if (char == "'") {
        // E'...' (and e'...') strings accept backslash escapes.
        final escapes = index > 0 &&
            (sql[index - 1] == 'E' || sql[index - 1] == 'e') &&
            (index < 2 || !_isIdentifierPart(sql[index - 2]));
        copyTo(_endOfQuoted(sql, index, "'", backslashEscapes: escapes));
      } else if (char == '"') {
        copyTo(_endOfQuoted(sql, index, '"'));
      } else if (char == '-' && next == '-') {
        final newline = sql.indexOf('\n', index);
        copyTo(newline < 0 ? len : newline);
      } else if (char == '/' && next == '*') {
        copyTo(_endOfBlockComment(sql, index));
      } else if (char == r'$' && _dollarTag(sql, index) != null) {
        final tag = _dollarTag(sql, index)!;
        final close = sql.indexOf(tag, index + tag.length);
        copyTo(close < 0 ? len : close + tag.length);
      } else if (char == '@') {
        // Parameter?
        // Check if next char is start of identifier
        if (index + 1 < len && _isIdentifierStart(sql[index + 1])) {
          final start = index + 1;
          index += 2;
          while (index < len && _isIdentifierPart(sql[index])) {
            index++;
          }
          final name = sql.substring(start, index);

          // Find parameter. As in Npgsql, its name may carry the `@` or `:`
          // prefix (`addWithValue('@id', 1)`): it was not found.
          final param = parameters.firstWhere(
              (p) =>
                  p.parameterName == name ||
                  p.parameterName == '@$name' ||
                  p.parameterName == ':$name',
              orElse: () =>
                  throw Exception('Parameter @$name not found in collection'));

          // Get or assign index
          int paramIdx;
          if (paramIndexMap.containsKey(name)) {
            paramIdx = paramIndexMap[name]!;
          } else {
            paramIdx = orderedParams.length + 1;
            paramIndexMap[name] = paramIdx;
            orderedParams.add(param);
          }

          sb.write('\$$paramIdx');
        } else {
          sb.write(char);
          index++;
        }
      } else if (char == '?') {
        // Positional parameter (PHP PDO style)
        if (paramIndexMap.isNotEmpty) {
          throw Exception(
              'Functionality of mixing named and positional parameters is not supported.');
        }

        if (positionalIndex >= parameters.length) {
          throw Exception(
              'No parameter defined for ? placeholder at index $index. Expected at least ${positionalIndex + 1} parameters.');
        }

        final param = parameters[positionalIndex];
        positionalIndex++;

        // For positional, each ? is a new binding in order.
        orderedParams.add(param);
        final paramIdx = orderedParams.length;
        sb.write('\$$paramIdx');
        index++;
      } else {
        if (char == r'$' &&
            next.isNotEmpty &&
            next.codeUnitAt(0) >= 48 &&
            next.codeUnitAt(0) <= 57 &&
            (index == 0 || !_isIdentifierPart(sql[index - 1]))) {
          sawNumberedPlaceholder = true;
        }
        sb.write(char);
        index++;
      }
    }

    // Only `$1, $2, ...`: the parameters bind in collection order. They used
    // to be dropped, so the statement failed (08P01, 42P02).
    if (orderedParams.isEmpty && sawNumberedPlaceholder) {
      return RewrittenSql(sql, parameters.toList());
    }

    return RewrittenSql(sb.toString(), orderedParams);
  }

  /// The index after the quoted text starting at [start] ([quote] doubled
  /// inside is an escaped quote; with [backslashEscapes], `\x` is too).
  static int _endOfQuoted(String sql, int start, String quote,
      {bool backslashEscapes = false}) {
    var i = start + 1;
    while (i < sql.length) {
      final c = sql[i];
      if (backslashEscapes && c == r'\') {
        i += 2;
        continue;
      }
      if (c == quote) {
        if (i + 1 < sql.length && sql[i + 1] == quote) {
          i += 2;
          continue;
        }
        return i + 1;
      }
      i++;
    }
    return sql.length;
  }

  /// The index after the (possibly nested) block comment at [start].
  static int _endOfBlockComment(String sql, int start) {
    var depth = 0;
    var i = start;
    while (i < sql.length) {
      if (sql.startsWith('/*', i)) {
        depth++;
        i += 2;
      } else if (sql.startsWith('*/', i)) {
        depth--;
        i += 2;
        if (depth == 0) return i;
      } else {
        i++;
      }
    }
    return sql.length;
  }

  /// The delimiter (`$$` or `$tag$`) of a dollar-quoted string starting at
  /// [start], or null when `$` starts something else (`$1`, an identifier
  /// part).
  static String? _dollarTag(String sql, int start) {
    if (start > 0 && _isIdentifierPart(sql[start - 1])) return null;
    var i = start + 1;
    if (i < sql.length && !_isIdentifierStart(sql[i]) && sql[i] != r'$') {
      return null;
    }
    while (i < sql.length && _isIdentifierPart(sql[i])) {
      i++;
    }
    if (i < sql.length && sql[i] == r'$') {
      return sql.substring(start, i + 1);
    }
    return null;
  }

  static bool _isIdentifierStart(String char) {
    final code = char.codeUnitAt(0);
    // a-z, A-Z, _
    return (code >= 65 && code <= 90) ||
        (code >= 97 && code <= 122) ||
        (code == 95);
  }

  static bool _isIdentifierPart(String char) {
    final code = char.codeUnitAt(0);
    // a-z, A-Z, _, 0-9
    return (code >= 65 && code <= 90) ||
        (code >= 97 && code <= 122) ||
        (code == 95) ||
        (code >= 48 && code <= 57);
  }
}
