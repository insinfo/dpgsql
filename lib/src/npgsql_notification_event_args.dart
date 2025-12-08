/// Represents the arguments passed to the Notification event.
class NpgsqlNotificationEventArgs {
  NpgsqlNotificationEventArgs(this.channel, this.payload, this.pid);

  /// Name of the channel on which the notification was sent.
  final String channel;

  /// Payload carried by the notification.
  final String payload;

  /// Process ID of the backend that sent the notification.
  final int pid;

  @override
  String toString() =>
      'Notification(Channel="$channel", Payload="$payload", PID=$pid)';
}
