import '../npgsql_parameter_collection.dart';
import '../npgsql_parameter.dart';

class RewrittenSql {
  final String sql;
  final List<NpgsqlParameter> orderedParameters;

  RewrittenSql(this.sql, this.orderedParameters);
}

class SqlRewriter {
  static RewrittenSql rewrite(
      String sql, NpgsqlParameterCollection parameters) {
    if (parameters.isEmpty) {
      return RewrittenSql(sql, []);
    }

    final sb = StringBuffer();
    final orderedParams = <NpgsqlParameter>[];
    final paramIndexMap = <String, int>{}; // Name -> Index (1-based)

    int index = 0;
    final len = sql.length;

    while (index < len) {
      final char = sql[index];

      if (char == "'") {
        // Skip string literal
        sb.write(char);
        index++;
        while (index < len) {
          final c = sql[index];
          sb.write(c);
          if (c == "'") {
            // Check for escaped quote ''
            if (index + 1 < len && sql[index + 1] == "'") {
              sb.write("'");
              index += 2;
              continue;
            }
            index++;
            break;
          }
          index++;
        }
      } else if (char == '"') {
        // Skip quoted identifier
        sb.write(char);
        index++;
        while (index < len) {
          final c = sql[index];
          sb.write(c);
          if (c == '"') {
            if (index + 1 < len && sql[index + 1] == '"') {
              sb.write('"');
              index += 2;
              continue;
            }
            index++;
            break;
          }
          index++;
        }
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

          // Find parameter
          final param = parameters.firstWhere((p) => p.parameterName == name,
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
      } else {
        sb.write(char);
        index++;
      }
    }

    return RewrittenSql(sb.toString(), orderedParams);
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
