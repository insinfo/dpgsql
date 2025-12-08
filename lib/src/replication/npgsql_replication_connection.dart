import 'dart:async';
import 'dart:typed_data';
import '../internal/npgsql_connector.dart';
import '../npgsql_connection_string_builder.dart';
import '../protocol/backend_messages.dart';
import 'logical_replication_protocol.dart';
import 'replication_messages.dart';

class NpgsqlReplicationConnection {
  final String _connectionString;
  NpgsqlConnector? _connector;

  NpgsqlReplicationConnection(String connectionString)
      : _connectionString = connectionString;

  Future<void> open() async {
    final builder = NpgsqlConnectionStringBuilder(_connectionString);
    // Replication connections require 'replication' property?
    // "replication=database" in connection string.

    // We need to modify the connector to send 'replication' in startup if needed.
    // NpgsqlConnector doesn't support generic properties well yet, mainly fixed ones.
    // But we can add 'replication' param to NpgsqlConnector.

    _connector = NpgsqlConnector(
      host: builder.host,
      port: builder.port,
      username: builder.username,
      password: builder.password,
      database: builder.database,
      sslMode: builder.sslMode,
      trustServerCertificate: builder.trustServerCertificate,
      encoding: builder.encoding,
      replication: true,
      // Helper to indicate replication?
      // For now, let's assume we can modify NpgsqlConnector to accept extra startup params
      // or set replication=database.
    );
    await _connector!.open();
  }

  Future<Stream<ReplicationMessage>> startReplication(
      String slotName, String publicationName) async {
    if (_connector == null) throw StateError('Connection not open');

    final sql =
        "START_REPLICATION SLOT $slotName LOGICAL 0/0 (proto_version '1', publication_names '$publicationName')";

    final response = await _connector!.executeCopyCommand(sql);
    if (response.kind != CopyResponseKind.copyBoth) {
      throw StateError(
          'Expected CopyBothResponse for replication, got ${response.kind}');
    }

    // Return a stream that reads packets
    return _replicationStream();
  }

  Stream<ReplicationMessage> _replicationStream() async* {
    while (true) {
      final packet = await _connector!.readCopyDataPacket();
      if (packet == null) {
        break; // End of stream?
      }

      final type = packet[0];
      if (type == 0x77) {
        // 'w' - WAL Data
        // Header: Byte1('w'), Int64 walStart, Int64 walEnd, Int64 sendTime
        // Total header size in packet: 1 + 8 + 8 + 8 = 25 bytes.

        // We can update tracking LSN here if we want to confirm receipt.
        // For now, we yield the message.
        if (packet.length < 25) continue;

        final msgData = packet.sublist(25);
        yield LogicalReplicationProtocol.parse(msgData);
      } else if (type == 0x6b) {
        // 'k' - KeepAlive
        // Byte1('k'), Int64 endWal, Int64 timestamp, Byte1 replyRequested
        if (packet.length < 18) continue;

        final bd = ByteData.sublistView(packet);
        final endWal = bd.getInt64(1, Endian.big);
        // final timestamp = bd.getInt64(9, Endian.big);
        final replyRequested = packet[17] == 1;

        if (replyRequested) {
          await _connector!.sendStandbyStatus(
              walReceived:
                  endWal, // Confirm up to what we got? Or just current?
              walFlushed:
                  endWal, // Assuming we processed/flushed everything so far
              walApplied: endWal, // Assuming application
              timestamp: DateTime.now().toUtc(),
              replyRequested: false);
        }
      }
    }
  }

  Future<void> close() async {
    await _connector?.close();
  }
}
