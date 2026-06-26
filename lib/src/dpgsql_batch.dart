import 'dpgsql_batch_command.dart';
import 'dpgsql_connection.dart';
import 'dpgsql_data_reader.dart';

class DpgsqlBatch {
  final DpgsqlConnection _connection;
  final List<DpgsqlBatchCommand> batchCommands = [];

  DpgsqlBatch(this._connection);

  DpgsqlBatchCommand createBatchCommand(String commandText) {
    final cmd = DpgsqlBatchCommand(commandText);
    batchCommands.add(cmd);
    return cmd;
  }

  Future<DpgsqlDataReader> executeReader() {
    return _connection.executeBatch(this);
  }
}
