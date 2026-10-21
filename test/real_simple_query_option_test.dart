// DpgsqlCommand.simpleQuery against a real server: a script (several
// statements) runs through the simple query protocol even with
// `Use Extended Query For Unparameterized Commands=true`.
import 'package:dpgsql/dpgsql.dart';
import 'package:test/test.dart';

import 'test_config.dart';

const _script = r'''
-- Why? A comment with ? and 'quotes'
create temp table simple_opt (id int primary key, name text);
insert into simple_opt values (1, 'a?b'), (2, 'c');
create or replace function pg_temp.simple_opt_fn() returns int
language plpgsql as $$
begin
  return 1; -- ; inside the body
end;
$$;
begin;
insert into simple_opt values (3, 'tx');
commit;
''';

void main() {
  late DpgsqlConnection conn;
  var available = true;

  setUp(() async {
    final opened = await openRealConnectionOrSkip(
        options: 'Use Extended Query For Unparameterized Commands=true;'
            'Max Auto Prepare=20;Auto Prepare Min Usages=2');
    if (opened == null) {
      available = false;
      return;
    }
    conn = opened;
  });

  tearDown(() async {
    if (available) await conn.close();
  });

  test('without simpleQuery a script is refused by the extended protocol',
      () async {
    if (!available) return;
    await expectLater(
        DpgsqlCommand(_script, conn).executeNonQuery(),
        throwsA(isA<PostgresException>()
            .having((e) => e.sqlState, 'sqlState', '42601')));
    // The connection is still usable.
    expect(await DpgsqlCommand('select 1', conn).executeScalar(), 1);
  });

  test('simpleQuery runs a whole script and sums the affected rows', () async {
    if (!available) return;
    final command = DpgsqlCommand(_script, conn)..simpleQuery = true;
    expect(await command.executeNonQuery(), 3);

    final rows =
        await DpgsqlCommand('select id, name from simple_opt order by id', conn)
            .executeRows();
    expect(rows, [
      [1, 'a?b'],
      [2, 'c'],
      [3, 'tx'],
    ]);
    expect(
        await DpgsqlCommand('select pg_temp.simple_opt_fn()', conn)
            .executeScalar(),
        1);
  });

  test('simpleQuery reads the results of every statement', () async {
    if (!available) return;
    final command = DpgsqlCommand('select 1 as a; select 2 as b, 3 as c', conn)
      ..simpleQuery = true;
    final reader = await command.executeReader();
    final results = <List<Object?>>[];
    do {
      while (await reader.read()) {
        results.add(
            [for (var i = 0; i < reader.fieldCount; i++) reader.getValue(i)]);
      }
    } while (await reader.nextResult());
    await reader.close();
    expect(results, [
      [1],
      [2, 3],
    ]);
  });

  test('an error in a later statement of the script is reported', () async {
    if (!available) return;
    final command = DpgsqlCommand(
        'create temp table simple_err (id int); '
        'insert into simple_err_missing values (1)',
        conn)
      ..simpleQuery = true;
    await expectLater(
        command.executeNonQuery(),
        throwsA(isA<PostgresException>()
            .having((e) => e.sqlState, 'sqlState', '42P01')));
    // The script is one implicit transaction: the create was rolled back.
    final exists = await DpgsqlCommand(
            "select to_regclass('pg_temp.simple_err') is not null", conn)
        .executeScalar();
    expect(exists, isFalse);
    expect(await DpgsqlCommand('select 1', conn).executeScalar(), 1);
  });

  test(
      'simpleQuery refuses parameters, prepared statements and the other '
      'execute methods', () async {
    if (!available) return;
    final withParameter = DpgsqlCommand('select @x', conn)
      ..parameters.addWithValue('x', 1)
      ..simpleQuery = true;
    expect(withParameter.executeReader(), throwsStateError);

    final prepared = DpgsqlCommand('select 1', conn);
    await prepared.prepare();
    prepared.simpleQuery = true;
    expect(prepared.executeNonQuery(), throwsStateError);

    final command = DpgsqlCommand('select 1', conn)..simpleQuery = true;
    expect(command.executeScalar(), throwsStateError);
    expect(command.executeRows(), throwsStateError);
    expect(command.executeMaps(), throwsStateError);
    expect(command.executePgRows(), throwsStateError);
  });
}
