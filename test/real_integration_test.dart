// Integration test requiring local Postgres server
// User: dart, Pass: dart, DB: postgres, Port: 5432

import 'package:dpgsql/dpgsql.dart';
import 'package:test/test.dart';

void main() {
  test('Real Integration Test', () async {
    // Only run if environment allows - for now we assume it is the user's wish
    const connString =
        'Host=localhost;Port=5432;Database=postgres;Username=dart;Password=dart;SSL Mode=Disable';
    final conn = NpgsqlConnection(connString);

    try {
      await conn.open();

      // Create table
      var cmd = conn.createCommand('DROP TABLE IF EXISTS test_dart_integ');
      await cmd.executeNonQuery();

      cmd = conn.createCommand(
          'CREATE TABLE test_dart_integ (id serial PRIMARY KEY, name text, val int, active boolean, scores int[])');
      await cmd.executeNonQuery();

      // Insert
      cmd = conn.createCommand(
          "INSERT INTO test_dart_integ (name, val, active, scores) VALUES ('Dart', 2024, true, '{1, 2, 3}')");
      final rows = await cmd.executeNonQuery();
      expect(
          rows,
          equals(
              1)); // Some drivers return 0/1 depending on protocol version/tags

      // Read
      cmd = conn.createCommand(
          "SELECT name, val, active, scores FROM test_dart_integ WHERE val = 2024");
      final reader = await cmd.executeReader();

      final hasRows = await reader.read();
      expect(hasRows, isTrue);
      expect(reader['name'], equals('Dart'));
      expect(reader['val'], equals(2024));
      expect(reader['active'], equals(true));

      final scores = reader['scores'];
      if (scores is List) {
        expect(scores, equals([1, 2, 3]));
      } else {
        expect(scores, equals('{1,2,3}'));
      }

      await reader.close();

      // Transaction
      final trans = await conn.beginTransaction();
      final cmdTrans = conn.createCommand(
          "INSERT INTO test_dart_integ (name, val) VALUES ('Trans', 999)");
      cmdTrans.transaction = trans;
      await cmdTrans.executeNonQuery();
      await trans.rollback();

      final cmdCheck = conn.createCommand(
          "SELECT count(*) FROM test_dart_integ WHERE val = 999");
      final reader2 = await cmdCheck.executeReader();
      await reader2.read();
      // count(*) returns int8 (bigint)
      expect(reader2[0], equals(0));
      await reader2.close();

      print('Real Integration Test Passed');
    } catch (e) {
      if (e.toString().contains('SocketException')) {
        print(
            'Skipping integration test: Postgres not found on localhost:5432');
        return;
      }
      rethrow;
    } finally {
      await conn.close();
    }
  });
}
