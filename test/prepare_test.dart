import 'package:dpgsql/dpgsql.dart';
import 'package:test/test.dart';

import 'test_config.dart';

void main() {
  test('Prepare and Execute Test', () async {
    final conn = await openRealConnectionOrSkip();
    if (conn == null) return;

    try {
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
      final cmd =
          conn.createCommand('SELECT val FROM table_prep WHERE id = @id');
      cmd.parameters.add(DpgsqlParameter('id', 1)); // Initial value

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
    } finally {
      await conn.close();
    }
  });

  test('Unprepared named parameters execute without double SQL rewrite',
      () async {
    final conn = await openRealConnectionOrSkip();
    if (conn == null) return;

    try {
      final cmd = conn.createCommand('SELECT @a::int + @b::int');
      cmd.parameters.addWithValue('a', 40);
      cmd.parameters.addWithValue('b', 2);

      final reader = await cmd.executeReader();
      try {
        expect(await reader.read(), isTrue);
        expect(reader.getValue(0), equals(42));
        expect(await reader.read(), isFalse);
      } finally {
        await reader.close();
      }
    } finally {
      await conn.close();
    }
  });
}
