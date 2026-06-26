import 'package:test/test.dart';

import 'test_config.dart';

void main() {
  test('Real COPY Integration Test', () async {
    final conn = await openRealConnectionOrSkip();
    if (conn == null) return;

    try {
      // Setup table
      await conn
          .createCommand('DROP TABLE IF EXISTS table_copy')
          .executeNonQuery();
      await conn
          .createCommand('CREATE TABLE table_copy (i int, t text)')
          .executeNonQuery();

      // Begin COPY
      final importer = await conn.beginBinaryImport(
          'COPY table_copy (i, t) FROM STDIN (FORMAT BINARY)');

      // Row 1
      await importer.startRow(2);
      await importer.write(100); // i
      await importer.write('Text 100'); // t

      // Row 2
      await importer.startRow(2);
      await importer.write(200);
      await importer.write<int?>(
          null); // Testing null if supported by basic handler (might fail if handler assumes non-null)

      print('Completing importer...');
      // Complete
      await importer.complete();
      print('Importer completed.');

      // Verify
      final reader = await conn
          .createCommand('SELECT i, t FROM table_copy ORDER BY i')
          .executeReader();

      await reader.read(); // Row 1
      expect(reader['i'], equals(100));
      expect(reader['t'], equals('Text 100'));

      await reader.read(); // Row 2
      expect(reader['i'], equals(200));
      // expect(reader['t'], isNull);

      await reader.close();

      print('Real COPY Integration Test Passed');
    } finally {
      await conn.close();
    }
  });
}
