import 'package:dpgsql/dpgsql.dart';
import 'package:test/test.dart';

void main() {
  test('Prepare and Execute Test', () async {
    const connString =
        'Host=localhost;Port=5432;Database=postgres;Username=dart;Password=dart;SSL Mode=Disable';
    final conn = NpgsqlConnection(connString);

    try {
      await conn.open();

      // Setup table
      await conn
          .createCommand('DROP TABLE IF EXISTS table_prep')
          .executeNonQuery();
      await conn
          .createCommand('CREATE TABLE table_prep (id int, val text)')
          .executeNonQuery();
      await conn
          .createCommand(
              "INSERT INTO table_prep (id, val) VALUES (1, 'One'), (2, 'Two')")
          .executeNonQuery();

      // Prepare Select
      final cmd = conn.createCommand('SELECT val FROM table_prep WHERE id = @id');
      cmd.parameters.add(NpgsqlParameter('id', 1)); // Initial value

      print('Preparing command...');
      await cmd.prepare();
      print('Command prepared.');

      // Execute 1
      print('Executing 1...');
      var reader = await cmd.executeReader();
      expect(await reader.read(), isTrue);
      expect(reader['val'], equals('One'));
      expect(await reader.read(), isFalse);
      await reader.close();

      // Execute 2 (Change param)
      print('Executing 2...');
      cmd.parameters[0].value = 2;
      reader = await cmd.executeReader();
      expect(await reader.read(), isTrue);
      expect(reader['val'], equals('Two'));
      expect(await reader.read(), isFalse);
      await reader.close();

      print('Prepare Test Passed');
    } catch (e) {
      if (e.toString().contains('SocketException') ||
          e.toString().contains('Connection refused')) {
        print('Skipping Prepare test: Postgres not found');
        return;
      }
      rethrow;
    } finally {
      await conn.close();
    }
  });
}
