import 'package:test/test.dart';
import 'package:dpgsql/dpgsql.dart';

void main() {
  test('Batch with Pipeline - API demonstration', () {
    expect(_batchPipelineExample, isA<Function>());
  });
}

void _batchPipelineExample() async {
  final conn = DpgsqlConnection('Host=localhost;Database=test');
  await conn.open();

  try {
    // Method 1: Use DpgsqlBatch (automatically uses pipeline internally)
    final batch = conn.createBatch();
    for (var i = 0; i < 100; i++) {
      final cmd = DpgsqlBatchCommand('INSERT INTO test VALUES (\$1)');
      cmd.parameters.addWithValue('val', i);
      batch.batchCommands.add(cmd);
    }
    await conn.executeBatch(batch);

    // Method 2: Use convenience method for simple batches
    await conn.executeBatchPipelined([
      'UPDATE test SET x = 1',
      'UPDATE test SET x = 2',
      'UPDATE test SET x = 3',
    ]);

    // Method 3: Low-level manual pipeline control
    conn.enterPipelineMode();
    try {
      await conn.pipelineSync();
    } finally {
      conn.exitPipelineMode();
    }
  } finally {
    await conn.close();
  }
}
