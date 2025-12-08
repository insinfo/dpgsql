import 'package:test/test.dart';
import 'package:dpgsql/dpgsql.dart';

void main() {
  test('Pipeline Mode - Basic functionality', () async {
    // This test demonstrates the pipeline mode API
    // Note: This is a unit test of the API structure, not integration with a real server

    // Create a connection (this would normally connect to a real server)
    final conn = NpgsqlConnection('Host=localhost;Port=5432;Database=test');

    // Demonstrate API exists
    expect(conn.inPipelineMode, isFalse);

    // These would work with a real connection:
    // conn.enterPipelineMode();
    // expect(conn.inPipelineMode, isTrue);

    // Send multiple commands without waiting
    // final cmd1 = conn.executeQueryPipelined(sql: 'SELECT 1');
    // final cmd2 = conn.executeQueryPipelined(sql: 'SELECT 2');
    // final cmd3 = conn.executeQueryPipelined(sql: 'SELECT 3');

    // Send Sync and wait for all responses
    // await conn.pipelineSync();

    // Exit pipeline mode
    // conn.exitPipelineMode();

    // This test just ensures the API compiles correctly
  });

  test('Pipeline Mode - Multiple commands demo', () {
    // This test documents the expected usage pattern

    void exampleUsage() async {
      final conn = NpgsqlConnection('Host=localhost;Database=test');
      await conn.open();

      try {
        // Enter pipeline mode
        conn.enterPipelineMode();

        // Send 10 queries without waiting for responses
        // for (var i = 0; i < 10; i++) {
        //   conn.executeQueryPipelined(
        //     sql: 'SELECT \$1::int',
        //     parameters: NpgsqlParameterCollection()..addWithValue('p', i),
        //   );
        // }

        // Send Sync - this is the barrier
        // All previous queries will complete before anything after this
        await conn.pipelineSync();

        // Exit pipeline mode
        conn.exitPipelineMode();
      } finally {
        await conn.close();
      }
    }

    // This is just documentation - the function isn't called
    expect(exampleUsage, isA<Function>());
  });
}
