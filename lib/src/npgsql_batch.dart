import 'npgsql_batch_command.dart';
import 'npgsql_connection.dart';
import 'npgsql_data_reader.dart';

class NpgsqlBatch {
  final NpgsqlConnection _connection;
  final List<NpgsqlBatchCommand> batchCommands = [];

  NpgsqlBatch(this._connection);

  NpgsqlBatchCommand createBatchCommand(String commandText) {
    final cmd = NpgsqlBatchCommand(commandText);
    batchCommands.add(cmd);
    return cmd;
  }

  Future<NpgsqlDataReader> executeReader() {
    return _connection.executeBatch(this);
  }
}
