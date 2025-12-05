import 'npgsql_exception.dart';

/// The exception that is thrown when the PostgreSQL backend reports an error.
/// Porting PostgresException.cs
class PostgresException extends NpgsqlException {
  PostgresException({
    required this.severity,
    required this.invariantSeverity,
    required this.sqlState,
    required this.messageText,
    this.detail,
    this.hint,
    this.position = 0,
    this.internalPosition = 0,
    this.internalQuery,
    this.where,
    this.schemaName,
    this.tableName,
    this.columnName,
    this.dataTypeName,
    this.constraintName,
    this.file,
    this.line,
    this.routine,
  }) : super(_formatMessage(sqlState, messageText, position, detail));

  final String severity;
  final String invariantSeverity;
  final String sqlState;
  final String messageText;
  final String? detail;
  final String? hint;
  final int position;
  final int internalPosition;
  final String? internalQuery;
  final String? where;
  final String? schemaName;
  final String? tableName;
  final String? columnName;
  final String? dataTypeName;
  final String? constraintName;
  final String? file;
  final String? line;
  final String? routine;

  factory PostgresException.fromFields(Map<String, String> fields) {
    return PostgresException(
      severity: fields['S'] ?? 'ERROR', // Localized severity
      invariantSeverity: fields['V'] ?? fields['S'] ?? 'ERROR',
      sqlState: fields['C'] ?? '00000', // Unknown state
      messageText: fields['M'] ?? 'Unknown error',
      detail: fields['D'],
      hint: fields['H'],
      position: int.tryParse(fields['P'] ?? '') ?? 0,
      internalPosition: int.tryParse(fields['p'] ?? '') ?? 0,
      internalQuery: fields['q'],
      where: fields['W'],
      schemaName: fields['s'],
      tableName: fields['t'],
      columnName: fields['c'],
      dataTypeName: fields['d'],
      constraintName: fields['n'],
      file: fields['F'],
      line: fields['L'],
      routine: fields['R'],
    );
  }

  // Helper to format the message string similar to Npgsql
  static String _formatMessage(
      String sqlState, String messageText, int position, String? detail) {
    var baseMessage = '$sqlState: $messageText';
    if (position != 0) {
      baseMessage += '\nPOSITION: $position';
    }
    if (detail != null) {
      baseMessage += '\nDETAIL: $detail';
    }
    return baseMessage;
  }
}
