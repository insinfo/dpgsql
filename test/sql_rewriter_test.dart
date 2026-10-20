// Placeholders inside comments, dollar-quoted strings and E'' strings are
// text, not parameters (1.0.3).

import 'package:dpgsql/dpgsql.dart';
import 'package:dpgsql/src/internal/sql_rewriter.dart';
import 'package:test/test.dart';

DpgsqlParameterCollection _params(int count) {
  final parameters = DpgsqlParameterCollection();
  for (var i = 0; i < count; i++) {
    parameters.add(DpgsqlParameter('p$i', i));
  }
  return parameters;
}

String _rewrite(String sql, int params) =>
    SqlRewriter.rewrite(sql, _params(params)).sql;

void main() {
  test('an apostrophe in a line comment does not open a string', () {
    expect(
        _rewrite("select ? -- the type's default ?\n, ? as b", 2),
        "select \$1 -- the type's default ?\n, \$2 as b");
  });

  test('block comments, nested', () {
    expect(_rewrite('select /* a ? /* b ? */ c ? */ ?', 1),
        'select /* a ? /* b ? */ c ? */ \$1');
  });

  test('dollar-quoted strings', () {
    expect(_rewrite(r"select $$ it's ? $$, $fn$ @x ? $fn$, ?", 1),
        r"select $$ it's ? $$, $fn$ @x ? $fn$, $1");
    // $1 written by hand is not a dollar quote.
    expect(_rewrite(r'select $1, ?', 1), r'select $1, $1');
  });

  test("E'' strings with backslash escapes", () {
    expect(_rewrite(r"select E'a\'?', ?", 1), r"select E'a\'?', $1");
    // In a standard string the backslash is not an escape.
    expect(_rewrite(r"select 'a\', ?", 1), r"select 'a\', $1");
  });

  test('named parameters keep working', () {
    final parameters = DpgsqlParameterCollection()
      ..add(DpgsqlParameter('a', 1))
      ..add(DpgsqlParameter('b', 2));
    final rewritten = SqlRewriter.rewrite(
        "select @a, @b, @a -- @c is not a parameter\n", parameters);
    expect(rewritten.sql, "select \$1, \$2, \$1 -- @c is not a parameter\n");
    expect(rewritten.orderedParameters.map((p) => p.parameterName), ['a', 'b']);
  });
}
