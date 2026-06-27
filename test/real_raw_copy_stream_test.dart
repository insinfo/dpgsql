import 'package:test/test.dart';

import 'test_config.dart';

void main() {
  test('raw COPY stream imports and exports CSV data', () async {
    final conn = await openRealConnectionOrSkip();
    if (conn == null) return;

    try {
      await conn
          .createCommand('DROP TABLE IF EXISTS table_raw_copy')
          .executeNonQuery();
      await conn
          .createCommand('CREATE TABLE table_raw_copy (id int, name text)')
          .executeNonQuery();

      final progress = <int>[];
      final importer = await conn.beginTextImport(
        'COPY table_raw_copy (id, name) FROM STDIN (FORMAT CSV)',
        onProgress: progress.add,
      );
      await importer.writeString('1,Alice\n');
      await importer.writeStream(Stream<List<int>>.fromIterable([
        '2,Bob\n'.codeUnits,
        '3,"Carol, D"\n'.codeUnits,
      ]));
      expect(importer.bytesTransferred, greaterThan(0));
      expect(progress, isNotEmpty);
      expect(progress.last, importer.bytesTransferred);
      await importer.complete();

      final count = await conn.executeScalar(
        'SELECT count(*)::int FROM table_raw_copy',
      );
      expect(count, 3);

      final exportProgress = <int>[];
      final exporter = await conn.beginTextExport(
        'COPY (SELECT id, name FROM table_raw_copy ORDER BY id) '
        'TO STDOUT (FORMAT CSV)',
        onProgress: exportProgress.add,
      );
      final csv = await exporter.readAsString();

      expect(csv, contains('1,Alice'));
      expect(csv, contains('2,Bob'));
      expect(csv, contains('3,"Carol, D"'));
      expect(exporter.isClosed, isTrue);
      expect(exporter.bytesTransferred, greaterThan(0));
      expect(exportProgress, isNotEmpty);
      expect(exportProgress.last, exporter.bytesTransferred);
    } finally {
      await conn.close();
    }
  });

  test('raw COPY stream cancel marks connection unsafe for pool reuse',
      () async {
    final conn = await openRealConnectionOrSkip();
    if (conn == null) return;

    try {
      await conn
          .createCommand('DROP TABLE IF EXISTS table_raw_copy_cancel')
          .executeNonQuery();
      await conn
          .createCommand('CREATE TABLE table_raw_copy_cancel (id int)')
          .executeNonQuery();

      final importer = await conn.beginTextImport(
        'COPY table_raw_copy_cancel (id) FROM STDIN (FORMAT CSV)',
      );
      await importer.writeString('1\n');
      await importer.cancel('test cancellation');

      expect(importer.isClosed, isTrue);
      expect(conn.isSafeToReturnToPool, isFalse);
    } finally {
      await conn.close();
    }
  });
}
