import 'dpgsql_batch_command.dart';
import 'postgres_exception.dart';

/// Exceção lançada quando uma execução de [DpgsqlBatch] falha parcialmente.
///
/// Espelha o comportamento do `PostgresBatchException` do Dpgsql original,
/// carregando a exceção raiz e o estado final de cada comando do batch.
class PostgresBatchException extends PostgresException {
  PostgresBatchException({
    required PostgresException inner,
    required List<DpgsqlBatchCommand> commands,
    required this.errorCommandIndex,
  })  : batchCommands = List<DpgsqlBatchCommand>.unmodifiable(commands),
        rootException = inner,
        super(
          severity: inner.severity,
          invariantSeverity: inner.invariantSeverity,
          sqlState: inner.sqlState,
          messageText: inner.messageText,
          detail: inner.detail,
          hint: inner.hint,
          position: inner.position,
          internalPosition: inner.internalPosition,
          internalQuery: inner.internalQuery,
          where: inner.where,
          schemaName: inner.schemaName,
          tableName: inner.tableName,
          columnName: inner.columnName,
          dataTypeName: inner.dataTypeName,
          constraintName: inner.constraintName,
          file: inner.file,
          line: inner.line,
          routine: inner.routine,
        );

  /// Exceção original disparada pelo backend.
  final PostgresException rootException;

  /// Snapshot imutável dos comandos do batch no momento da falha.
  final List<DpgsqlBatchCommand> batchCommands;

  /// Índice do comando que originou o erro, ou -1 quando indeterminado.
  final int errorCommandIndex;

  /// Referência direta ao comando problemático, quando disponível.
  DpgsqlBatchCommand? get failedCommand {
    if (errorCommandIndex < 0 || errorCommandIndex >= batchCommands.length) {
      return null;
    }
    return batchCommands[errorCommandIndex];
  }

  @override
  String toString() {
    final failed = failedCommand;
    final failedInfo = failed != null
        ? ' (Command ${errorCommandIndex + 1}: ${failed.commandText})'
        : '';
    return 'PostgresBatchException$failedInfo: ${super.message}';
  }
}
