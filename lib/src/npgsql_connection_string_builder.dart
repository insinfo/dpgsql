import 'dart:convert';
import 'ssl_mode.dart';
// import 'package:galileo_utf/galileo_utf.dart'; // Uncomment if using galileo_utf for more encodings

/// Provides a simple way to create and manage the contents of connection strings used by the NpgsqlConnection class.
/// Porting NpgsqlConnectionStringBuilder.cs
class NpgsqlConnectionStringBuilder {
  final Map<String, String> _parameters = {};

  NpgsqlConnectionStringBuilder([String? connectionString]) {
    if (connectionString != null && connectionString.isNotEmpty) {
      _parse(connectionString);
    }
  }

  String get clientEncoding =>
      _parameters['Client Encoding'] ?? _parameters['Encoding'] ?? 'UTF8';
  set clientEncoding(String value) => _parameters['Client Encoding'] = value;

  Encoding get encoding {
    final enc = clientEncoding.toUpperCase();
    switch (enc) {
      case 'UTF8':
      case 'UTF-8':
        return utf8;
      case 'LATIN1':
      case 'ISO-8859-1':
        return latin1;
      case 'ASCII':
        return ascii;
      // Add more as needed or use package:charset
      default:
        // Fallback or throw?
        if (enc == 'WIN1252') {
          // Dart doesn't have built-in Win1252, usually mapped to Latin1 with differences.
          // For now return latin1 or TODO: Use galileo_utf
          return latin1;
        }
        return utf8;
    }
  }

  String get host => _parameters['Host'] ?? 'localhost';
  set host(String value) => _parameters['Host'] = value;

  int get port => int.tryParse(_parameters['Port'] ?? '5432') ?? 5432;
  set port(int value) => _parameters['Port'] = value.toString();

  String get username =>
      _parameters['Username'] ?? _parameters['User ID'] ?? 'postgres';
  set username(String value) {
    _parameters['Username'] = value;
    _parameters.remove('User ID');
  }

  String get password => _parameters['Password'] ?? '';
  set password(String value) => _parameters['Password'] = value;

  String get database => _parameters['Database'] ?? 'postgres';
  set database(String value) => _parameters['Database'] = value;

  SslMode get sslMode {
    final val = _parameters['SSL Mode'] ?? _parameters['SslMode'];
    if (val == null) return SslMode.disable;
    switch (val.toLowerCase()) {
      case 'disable':
        return SslMode.disable;
      case 'allow':
        return SslMode.allow;
      case 'prefer':
        return SslMode.prefer;
      case 'require':
        return SslMode.require;
      case 'verify-ca':
      case 'verifyca':
        return SslMode.verifyCa;
      case 'verify-full':
      case 'verifyfull':
        return SslMode.verifyFull;
      default:
        return SslMode.disable;
    }
  }

  set sslMode(SslMode value) {
    switch (value) {
      case SslMode.disable:
        _parameters['SSL Mode'] = 'Disable';
        break;
      case SslMode.allow:
        _parameters['SSL Mode'] = 'Allow';
        break;
      case SslMode.prefer:
        _parameters['SSL Mode'] = 'Prefer';
        break;
      case SslMode.require:
        _parameters['SSL Mode'] = 'Require';
        break;
      case SslMode.verifyCa:
        _parameters['SSL Mode'] = 'VerifyCA';
        break;
      case SslMode.verifyFull:
        _parameters['SSL Mode'] = 'VerifyFull';
        break;
    }
  }

  bool get trustServerCertificate {
    final val = _parameters['Trust Server Certificate'] ??
        _parameters['TrustServerCertificate'];
    return val?.toLowerCase() == 'true';
  }

  set trustServerCertificate(bool value) {
    _parameters['Trust Server Certificate'] = value.toString();
  }

  String? operator [](String keyword) => _parameters[keyword];
  void operator []=(String keyword, String? value) {
    if (value == null) {
      _parameters.remove(keyword);
    } else {
      _parameters[keyword] = value;
    }
  }

  void _parse(String connectionString) {
    final parts = connectionString.split(';');
    for (final part in parts) {
      final kv = part.split('=');
      if (kv.length == 2) {
        final key = kv[0].trim();
        final value = kv[1].trim();
        // Normalize keys if needed, but Npgsql is case-insensitive usually.
        // We store as provided, but getters handle aliases.
        // Actually, let's store with proper casing or handle in getters.
        // Simple map for now.
        _parameters[key] = value;
      }
    }
  }

  @override
  String toString() {
    final sb = StringBuffer();
    _parameters.forEach((key, value) {
      sb.write('$key=$value;');
    });
    return sb.toString();
  }
}
