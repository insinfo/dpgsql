import 'npgsql_parameter_collection.dart';
import 'postgres_exception.dart';

class NpgsqlBatchCommand {
  String commandText;
  final NpgsqlParameterCollection parameters = NpgsqlParameterCollection();

  /// Resultado do comando após execução (rows afetadas).
  int recordsAffected = 0;

  /// Tag textual retornada pelo servidor (ex: "INSERT 0 1").
  String? commandTag;

  /// Exceção capturada para este comando, quando a execução falha.
  PostgresException? exception;

  NpgsqlBatchCommand(this.commandText);
}
