import 'dpgsql_command.dart';
import 'dpgsql_connection.dart';
import 'dpgsql_data_adapter.dart';

/// Creates SQL commands for simple insert, update and delete operations.
///
/// Porting surface for NpgsqlCommandBuilder. Dart does not have ADO.NET
/// DataTable metadata, so this class exposes explicit table/column inputs.
class DpgsqlCommandBuilder {
  DpgsqlCommandBuilder([this.dataAdapter]) {
    quotePrefix = '"';
    quoteSuffix = '"';
  }

  DpgsqlDataAdapter? dataAdapter;

  String _quotePrefix = '"';
  String _quoteSuffix = '"';

  String get quotePrefix => _quotePrefix;
  set quotePrefix(String value) {
    _quotePrefix = value.isEmpty ? value : '"';
  }

  String get quoteSuffix => _quoteSuffix;
  set quoteSuffix(String value) {
    _quoteSuffix = value.isEmpty ? value : '"';
  }

  String quoteIdentifier(String identifier) {
    if (identifier == '*') {
      return identifier;
    }
    if (identifier.startsWith(quotePrefix) &&
        identifier.endsWith(quoteSuffix)) {
      return identifier;
    }
    return '$quotePrefix${identifier.replaceAll(quoteSuffix, quoteSuffix + quoteSuffix)}$quoteSuffix';
  }

  String unquoteIdentifier(String identifier) {
    if (quotePrefix.isNotEmpty &&
        quoteSuffix.isNotEmpty &&
        identifier.startsWith(quotePrefix) &&
        identifier.endsWith(quoteSuffix)) {
      return identifier
          .substring(quotePrefix.length, identifier.length - quoteSuffix.length)
          .replaceAll(quoteSuffix + quoteSuffix, quoteSuffix);
    }
    return identifier;
  }

  String quoteQualifiedIdentifier(String identifier) {
    return identifier.split('.').map(quoteIdentifier).join('.');
  }

  DpgsqlCommand getInsertCommand(
    String tableName,
    Iterable<String> columns, {
    DpgsqlConnection? connection,
    bool useColumnsForParameterNames = false,
  }) {
    final columnList = columns.toList(growable: false);
    final quotedColumns = columnList.map(quoteIdentifier).join(', ');
    final parameters = columnList
        .asMap()
        .entries
        .map((entry) =>
            '@${useColumnsForParameterNames ? entry.value : 'p${entry.key + 1}'}')
        .join(', ');
    return DpgsqlCommand(
      'INSERT INTO ${quoteQualifiedIdentifier(tableName)} ($quotedColumns) VALUES ($parameters)',
      connection,
    );
  }

  DpgsqlCommand getUpdateCommand(
    String tableName,
    Iterable<String> columns,
    Iterable<String> keyColumns, {
    DpgsqlConnection? connection,
    bool useColumnsForParameterNames = false,
  }) {
    final columnList = columns.toList(growable: false);
    final keyList = keyColumns.toList(growable: false);
    final setClause = columnList.asMap().entries.map((entry) {
      final parameterName =
          useColumnsForParameterNames ? entry.value : 'p${entry.key + 1}';
      return '${quoteIdentifier(entry.value)} = @$parameterName';
    }).join(', ');
    final whereClause = keyList.asMap().entries.map((entry) {
      final parameterName = useColumnsForParameterNames
          ? 'original_${entry.value}'
          : 'k${entry.key + 1}';
      return '${quoteIdentifier(entry.value)} = @$parameterName';
    }).join(' AND ');
    return DpgsqlCommand(
      'UPDATE ${quoteQualifiedIdentifier(tableName)} SET $setClause WHERE $whereClause',
      connection,
    );
  }

  DpgsqlCommand getDeleteCommand(
    String tableName,
    Iterable<String> keyColumns, {
    DpgsqlConnection? connection,
    bool useColumnsForParameterNames = false,
  }) {
    final keyList = keyColumns.toList(growable: false);
    final whereClause = keyList.asMap().entries.map((entry) {
      final parameterName =
          useColumnsForParameterNames ? entry.value : 'k${entry.key + 1}';
      return '${quoteIdentifier(entry.value)} = @$parameterName';
    }).join(' AND ');
    return DpgsqlCommand(
      'DELETE FROM ${quoteQualifiedIdentifier(tableName)} WHERE $whereClause',
      connection,
    );
  }

  static Future<void> deriveParameters(DpgsqlCommand command) async {
    throw UnsupportedError(
      'DpgsqlCommandBuilder.deriveParameters is not implemented yet.',
    );
  }
}
