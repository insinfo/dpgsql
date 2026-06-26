import 'dart:io';

import 'package:dpgsql/dpgsql.dart';

String realConnectionString({String? options}) {
  final env = Platform.environment;
  final explicit = env['DPGSQL_TEST_DB'];
  final base = explicit != null && explicit.trim().isNotEmpty
      ? explicit.trim()
      : _connectionStringFromPgEnvironment(env);

  if (options == null || options.trim().isEmpty) {
    return base;
  }

  final separator = base.trimRight().endsWith(';') ? '' : ';';
  return '$base$separator$options';
}

Future<DpgsqlConnection?> openRealConnectionOrSkip({String? options}) async {
  final conn = DpgsqlConnection(realConnectionString(options: options));
  try {
    await conn.open();
    return conn;
  } catch (e) {
    await conn.close();
    if (_hasExplicitRealDbConfig()) {
      rethrow;
    }
    if (_isConnectionUnavailable(e)) {
      print('Skipping real PostgreSQL test: $e');
      return null;
    }
    rethrow;
  }
}

Future<Object?> executeScalar(
  DpgsqlConnection conn,
  String sql, [
  Map<String, Object?> parameters = const {},
]) async {
  final cmd = conn.createCommand(sql);
  parameters.forEach((name, value) {
    cmd.parameters.addWithValue(name, value);
  });

  final reader = await cmd.executeReader();
  try {
    if (!await reader.read()) {
      return null;
    }
    return reader.getValue(0);
  } finally {
    await reader.close();
  }
}

String _connectionStringFromPgEnvironment(Map<String, String> env) {
  final host = env['PGHOST'] ?? env['POSTGRES_HOST'] ?? 'localhost';
  final port = env['PGPORT'] ?? env['POSTGRES_PORT'] ?? '5432';
  final database = env['PGDATABASE'] ?? env['POSTGRES_DB'] ?? 'postgres';
  final username = env['PGUSER'] ?? env['POSTGRES_USER'] ?? 'dart';
  final password = env['PGPASSWORD'] ?? env['POSTGRES_PASSWORD'] ?? 'dart';
  final sslMode = env['PGSSLMODE'] ?? env['POSTGRES_SSLMODE'] ?? 'Disable';

  return 'Host=$host;Port=$port;Database=$database;'
      'Username=$username;Password=$password;SSL Mode=$sslMode';
}

bool _hasExplicitRealDbConfig() {
  final env = Platform.environment;
  return env.containsKey('DPGSQL_TEST_DB') ||
      env.containsKey('PGHOST') ||
      env.containsKey('POSTGRES_HOST') ||
      env['CI'] == 'true';
}

bool _isConnectionUnavailable(Object error) {
  final text = error.toString();
  return error is SocketException ||
      text.contains('SocketException') ||
      text.contains('Connection refused') ||
      text.contains('Failed host lookup');
}
