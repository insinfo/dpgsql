import 'package:test/test.dart';

import 'test_config.dart';

void main() {
  test('real connection receives LISTEN/NOTIFY payloads', () async {
    final conn = await openRealConnectionOrSkip();
    if (conn == null) return;

    final channel = 'dpgsql_notify_${DateTime.now().microsecondsSinceEpoch}';

    try {
      await conn.createCommand('LISTEN $channel').executeNonQuery();

      final notificationFuture = conn.notifications
          .firstWhere((n) => n.channel == channel)
          .timeout(const Duration(seconds: 5));

      await conn
          .createCommand("NOTIFY $channel, 'driver-notification-payload'")
          .executeNonQuery();

      final notification = await notificationFuture;
      expect(notification.channel, equals(channel));
      expect(notification.payload, equals('driver-notification-payload'));
      expect(notification.pid, greaterThan(0));
    } finally {
      try {
        await conn.createCommand('UNLISTEN $channel').executeNonQuery();
      } finally {
        await conn.close();
      }
    }
  });
}
