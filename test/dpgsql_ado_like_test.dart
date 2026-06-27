import 'package:dpgsql/dpgsql.dart';
import 'package:test/test.dart';

void main() {
  test('DpgsqlCommandBuilder quotes identifiers and builds commands', () {
    final builder = DpgsqlCommandBuilder();

    expect(builder.quoteIdentifier('select'), '"select"');
    expect(builder.quoteIdentifier('a"b'), '"a""b"');
    expect(builder.unquoteIdentifier('"a""b"'), 'a"b');
    expect(
        builder.quoteQualifiedIdentifier('public.people'), '"public"."people"');

    final insert = builder.getInsertCommand(
      'public.people',
      ['id', 'name'],
    );
    expect(
      insert.commandText,
      'INSERT INTO "public"."people" ("id", "name") VALUES (@p1, @p2)',
    );

    final update = builder.getUpdateCommand(
      'people',
      ['name'],
      ['id'],
      useColumnsForParameterNames: true,
    );
    expect(
      update.commandText,
      'UPDATE "people" SET "name" = @name WHERE "id" = @original_id',
    );

    final delete = builder.getDeleteCommand('people', ['id']);
    expect(delete.commandText, 'DELETE FROM "people" WHERE "id" = @k1');
  });

  test('DpgsqlDataAdapter keeps typed commands and row events', () {
    final select = DpgsqlCommand('SELECT 1');
    final adapter = DpgsqlDataAdapter(select);
    adapter.insertCommand = DpgsqlCommand('INSERT INTO t VALUES (@p1)');

    var updatingCalled = false;
    var updatedCalled = false;

    adapter.rowUpdating = (sender, args) {
      updatingCalled = true;
      expect(identical(sender, adapter), isTrue);
      expect(args.statementType, DpgsqlStatementType.insert);
    };
    adapter.rowUpdated = (sender, args) {
      updatedCalled = true;
      expect(args.recordsAffected, 1);
    };

    adapter.onRowUpdating(DpgsqlRowUpdatingEventArgs(
      command: adapter.insertCommand,
      statementType: DpgsqlStatementType.insert,
    ));
    adapter.onRowUpdated(DpgsqlRowUpdatedEventArgs(
      command: adapter.insertCommand,
      statementType: DpgsqlStatementType.insert,
      recordsAffected: 1,
    ));

    expect(adapter.selectCommand, same(select));
    expect(updatingCalled, isTrue);
    expect(updatedCalled, isTrue);
  });

  test('DpgsqlMetricsOptions is available as an observability extension point',
      () {
    expect(const DpgsqlMetricsOptions(), isA<DpgsqlMetricsOptions>());
  });
}
