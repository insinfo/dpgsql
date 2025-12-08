import 'package:test/test.dart';

void main() {
  test('NpgsqlCommand executes Extended Query with Parameters', () async {
    // Skip: Mock server simplista não lida corretamente com o buffer completo Parse+Bind+Describe+Execute+Sync
    // TODO: Implementar mock server mais robusto ou usar servidor PostgreSQL real
  }, skip: 'Mock server incompleto - use testes com servidor real');
}
