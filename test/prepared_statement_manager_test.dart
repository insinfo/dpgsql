import 'package:dpgsql/src/internal/prepared_statement.dart';
import 'package:test/test.dart';

void main() {
  test('beginAutoPrepare falls back when no slot can be reserved', () {
    final manager = PreparedStatementManager(
      maxAutoPrepared: 1,
      usagesBeforeAutoPrepare: 1,
    );

    final explicit = PreparedStatement(
      manager: manager,
      sql: 'SELECT explicit',
      isExplicit: true,
    )
      ..name = '_p_explicit'
      ..state = PreparedState.prepared
      ..autoPreparedSlotIndex = 0
      ..refreshLastUsed();
    manager.autoPrepared.add(explicit);

    final candidate = PreparedStatement.createAutoPrepareCandidate(
      manager: manager,
      sql: 'SELECT candidate',
    )..setParamTypes(const <int>[]);

    expect(manager.beginAutoPrepare(candidate, const <int>[]), isNull);
    expect(manager.autoPrepared.single, same(explicit));
    expect(candidate.state, PreparedState.notPrepared);
    expect(candidate.autoPreparedSlotIndex, equals(-1));
  });
}
