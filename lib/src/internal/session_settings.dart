import '../dpgsql_connection.dart';
import '../dpgsql_connection_string_builder.dart';
import 'dpgsql_connector.dart';

const defaultSessionSettingsTimeout = Duration(milliseconds: 100);

Future<void> applyConfiguredSessionSettings(
  DpgsqlConnection connection,
  DpgsqlConnectionStringBuilder builder, {
  DpgsqlConnector? connector,
  bool restoreStartupParameters = false,
  Duration timeout = defaultSessionSettingsTimeout,
  bool ignoreErrors = false,
}) async {
  final statements = <String>[];

  if (restoreStartupParameters && connector != null) {
    final clientEncoding = connector.clientEncoding;
    if (clientEncoding != null && clientEncoding.isNotEmpty) {
      statements
          .add("SET client_encoding = ${quoteSqlLiteral(clientEncoding)}");
    }
    if (connector.timeZone.value.isNotEmpty) {
      statements
          .add("SET TIME ZONE ${quoteSqlLiteral(connector.timeZone.value)}");
    }
  }

  final searchPath = builder.searchPath;
  if (searchPath != null && searchPath.trim().isNotEmpty) {
    statements.add('SET search_path TO $searchPath');
  }

  final applicationName = builder.applicationName;
  if (applicationName != null && applicationName.isNotEmpty) {
    statements
        .add('SET application_name TO ${quoteSqlLiteral(applicationName)}');
  }

  final statementTimeout = builder.statementTimeout;
  if (statementTimeout != null && statementTimeout.isNotEmpty) {
    statements
        .add('SET statement_timeout = ${quoteSqlLiteral(statementTimeout)}');
  }

  final lockTimeout = builder.lockTimeout;
  if (lockTimeout != null && lockTimeout.isNotEmpty) {
    statements.add('SET lock_timeout = ${quoteSqlLiteral(lockTimeout)}');
  }

  final idleTimeout = builder.idleInTransactionSessionTimeout;
  if (idleTimeout != null && idleTimeout.isNotEmpty) {
    statements.add(
      'SET idle_in_transaction_session_timeout = ${quoteSqlLiteral(idleTimeout)}',
    );
  }

  for (final sql in statements) {
    try {
      await connection.createCommand(sql).executeNonQuery().timeout(timeout);
    } catch (_) {
      if (!ignoreErrors) {
        rethrow;
      }
    }
  }
}

String quoteSqlLiteral(String value) => "'${value.replaceAll("'", "''")}'";
