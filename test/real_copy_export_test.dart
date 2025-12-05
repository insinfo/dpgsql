import 'package:dpgsql/dpgsql.dart';
import 'package:test/test.dart';

void main() {
  test('Real COPY Export Integration Test', () async {
    const connString =
        'Host=localhost;Port=5432;Database=postgres;Username=dart;Password=dart;SSL Mode=Disable';
    final conn = NpgsqlConnection(connString);

    try {
      await conn.open();

      // Setup table
      await conn
          .createCommand('DROP TABLE IF EXISTS table_copy_out')
          .executeNonQuery();
      await conn
          .createCommand(
              'CREATE TABLE table_copy_out (i int, t text, f float8)')
          .executeNonQuery();

      // Insert data
      await conn
          .createCommand(
              "INSERT INTO table_copy_out (i, t, f) VALUES (1, 'One', 1.1)")
          .executeNonQuery();
      await conn
          .createCommand(
              "INSERT INTO table_copy_out (i, t, f) VALUES (2, 'Two', 2.2)")
          .executeNonQuery();
      await conn
          .createCommand(
              "INSERT INTO table_copy_out (i, t, f) VALUES (3, NULL, 3.3)")
          .executeNonQuery();

      // Begin COPY Export
      print('Starting Binary Export...');
      final exporter = await conn.beginBinaryExport(
          'COPY table_copy_out (i, t, f) TO STDOUT (FORMAT BINARY)');

      // Row 1
      var cols = await exporter.startRow();
      expect(cols, equals(3));
      expect(await exporter.read<int>(), equals(1));
      expect(await exporter.read<String>(), equals('One'));
      expect(await exporter.read<double>(), equals(1.1));

      // Row 2
      cols = await exporter.startRow();
      expect(cols, equals(3));
      expect(await exporter.read<int>(), equals(2));
      expect(await exporter.read<String>(), equals('Two'));
      expect(await exporter.read<double>(), equals(2.2));

      // Row 3
      cols = await exporter.startRow();
      expect(cols, equals(3));
      expect(await exporter.read<int>(), equals(3));
      expect(await exporter.read<String>(), isNull);
      expect(await exporter.read<double>(), equals(3.3));

      // End
      cols = await exporter.startRow();
      expect(cols, equals(-1)); // End of data

      await exporter.dispose();
      print('Binary Export Completed.');

      print('Real COPY Export Integration Test Passed');
    } catch (e) {
      if (e.toString().contains('SocketException') ||
          e.toString().contains('Connection refused')) {
        print('Skipping COPY Export test: Postgres not found');
        return;
      }
      rethrow;
    } finally {
      await conn.close();
    }
  });
}
