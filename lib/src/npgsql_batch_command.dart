import 'npgsql_parameter_collection.dart';

class NpgsqlBatchCommand {
  String commandText;
  final NpgsqlParameterCollection parameters = NpgsqlParameterCollection();

  NpgsqlBatchCommand(this.commandText);
}
