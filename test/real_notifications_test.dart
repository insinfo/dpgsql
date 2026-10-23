// Regression tests for 1.0.3: LISTEN notifications while the connection is
// idle, UTF-8 protocol strings, and close() after the server ended the
// session.

import 'package:dpgsql/dpgsql.dart';
import 'package:test/test.dart';

import 'test_config.dart';

void main() {
  test('notifications arrive while no command is running', () async {
    final listener = await openRealConnectionOrSkip();
    if (listener == null) return;
    final sender = await openRealConnectionOrSkip();
    try {
      await listener.createCommand('LISTEN "dpgsql_idle"').executeNonQuery();
      final received = listener.notifications.first;

      await sender!
          .createCommand("NOTIFY \"dpgsql_idle\", 'olá ç'")
          .executeNonQuery();

      // They used to be read only by the next command on the listener.
      final notification = await received.timeout(const Duration(seconds: 3));
      expect(notification.channel, 'dpgsql_idle');
      expect(notification.payload, 'olá ç');

      // The connection still runs commands normally afterwards.
      expect(await listener.executeMaps('select 1 as one'), [
        {'one': 1}
      ]);
    } finally {
      await listener.close();
      await sender?.close();
    }
  });

  test('column names and error messages are decoded as UTF-8', () async {
    final conn = await openRealConnectionOrSkip();
    if (conn == null) return;
    try {
      final rows = await conn.executeMaps('select 1 as "situação"');
      expect(rows.single.keys, ['situação']);

      await expectLater(
          conn.executeMaps("select * from \"tabela_inexistente_ção\""),
          throwsA(isA<PostgresException>()
              .having((e) => e.messageText, 'messageText', contains('ção'))));
    } finally {
      await conn.close();
    }
  });

  test('onConnectionLost and close() after the backend is terminated',
      () async {
    final victim = await openRealConnectionOrSkip();
    if (victim == null) return;
    final killer = await openRealConnectionOrSkip();
    try {
      final pid = (await victim.executeMaps('select pg_backend_pid() as pid'))
          .single['pid'];
      final lost = victim.onConnectionLost.first;
      await killer!.executeMaps('select pg_terminate_backend($pid)');
      await lost.timeout(const Duration(seconds: 3));

      // Writing Terminate to the closed socket used to raise an uncaught
      // error.
      await victim.close();
      expect(victim.state, ConnectionState.closed);
    } finally {
      await killer?.close();
    }
  });
}
