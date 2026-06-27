import 'dart:io';
import 'dart:convert';

import 'ssl_mode.dart';
import 'timezone_database_scope.dart';
import 'timezone_settings.dart';
import 'utils/codecs/big5.dart' as dpgsql_big5;
import 'utils/codecs/dos.dart' as dpgsql_dos;
import 'utils/codecs/gbk.dart' as dpgsql_gbk;
import 'utils/codecs/koi8.dart' as dpgsql_koi8;
import 'utils/codecs/latin.dart' as dpgsql_latin;
import 'utils/codecs/windows.dart' as dpgsql_windows;

/// Provides a simple way to create and manage the contents of connection strings used by the DpgsqlConnection class.
/// Porting DpgsqlConnectionStringBuilder.cs
class DpgsqlConnectionStringBuilder {
  final Map<String, String> _parameters = {};

  DpgsqlConnectionStringBuilder([String? connectionString]) {
    if (connectionString != null && connectionString.isNotEmpty) {
      _parse(connectionString);
    }
  }

  String get clientEncoding =>
      _get('Client Encoding', 'ClientEncoding') ??
      _get('Encoding') ??
      Platform.environment['PGCLIENTENCODING'] ??
      'UTF8';
  set clientEncoding(String value) => _parameters['Client Encoding'] = value;

  /// Local text codec used by the Dart driver to encode/decode textual
  /// protocol data. Mirrors Dpgsql's `Encoding` keyword.
  Encoding get encoding => _resolveEncoding(_get('Encoding') ?? clientEncoding);

  set encodingName(String value) => _parameters['Encoding'] = value;

  /// PostgreSQL client_encoding value sent in the StartupMessage.
  String get postgresClientEncoding => _postgresEncodingName(clientEncoding);

  TimeZoneSettings get timeZone {
    final value = _get('TimeZone', 'Timezone', 'Time Zone') ?? 'UTC';
    return TimeZoneSettings(
      value,
      forceDecodeTimestamptzAsUTC: _getBool(
        true,
        'Force Decode Timestamptz As UTC',
        'ForceDecodeTimestamptzAsUTC',
      ),
      forceDecodeTimestampAsUTC: _getBool(
        true,
        'Force Decode Timestamp As UTC',
        'ForceDecodeTimestampAsUTC',
      ),
      forceDecodeDateAsUTC: _getBool(
        true,
        'Force Decode Date As UTC',
        'ForceDecodeDateAsUTC',
      ),
      useCurrentOffsetForLocalTimestamp: _getBool(
        true,
        'Use Current Offset For Local Timestamp',
        'UseCurrentOffsetForLocalTimestamp',
      ),
      useIanaTimeZoneDatabase: _getBool(
        false,
        'Use IANA Time Zone Database',
        'UseIanaTimeZoneDatabase',
        'Use Pg Time Zone Database',
        'UsePgTimeZoneDatabase',
      ),
      ianaTimeZoneDatabaseScope: parsePgTimeZoneDatabaseScope(
        _get(
              'IANA Time Zone Database Scope',
              'IanaTimeZoneDatabaseScope',
              'Pg Time Zone Database Scope',
            ) ??
            _get(
              'PgTimeZoneDatabaseScope',
              'Time Zone Database Scope',
              'TimeZoneDatabaseScope',
            ) ??
            'latest_all',
      ),
      throwOnDateTimeInfinity: _getBool(
        false,
        'Throw On DateTime Infinity',
        'ThrowOnDateTimeInfinity',
        'Throw On Infinity',
        'ThrowOnInfinity',
      ),
    );
  }

  set timeZone(TimeZoneSettings value) {
    _parameters['TimeZone'] = value.value;
    _parameters['Force Decode Timestamptz As UTC'] =
        value.forceDecodeTimestamptzAsUTC.toString();
    _parameters['Force Decode Timestamp As UTC'] =
        value.forceDecodeTimestampAsUTC.toString();
    _parameters['Force Decode Date As UTC'] =
        value.forceDecodeDateAsUTC.toString();
    _parameters['Use Current Offset For Local Timestamp'] =
        value.useCurrentOffsetForLocalTimestamp.toString();
    _parameters['Use IANA Time Zone Database'] =
        value.useIanaTimeZoneDatabase.toString();
    _parameters['IANA Time Zone Database Scope'] =
        pgTimeZoneDatabaseScopeName(value.ianaTimeZoneDatabaseScope);
    _parameters['Throw On DateTime Infinity'] =
        value.throwOnDateTimeInfinity.toString();
  }

  static Encoding _resolveEncoding(String name) {
    switch (_normalizeEncodingName(name)) {
      case 'UTF8':
        return utf8;
      case 'SQLASCII':
      case 'LATIN1':
        return latin1;
      case 'ASCII':
        return ascii;
      case 'LATIN2':
        return const dpgsql_latin.Latin2Codec();
      case 'LATIN3':
        return const dpgsql_latin.Latin3Codec();
      case 'LATIN4':
        return const dpgsql_latin.Latin4Codec();
      case 'LATIN5':
        return const dpgsql_latin.Latin9Codec();
      case 'LATIN6':
        return const dpgsql_latin.Latin10Codec();
      case 'LATIN7':
        return const dpgsql_latin.Latin13Codec();
      case 'LATIN8':
        return const dpgsql_latin.Latin14Codec();
      case 'LATIN9':
        return const dpgsql_latin.Latin15Codec();
      case 'LATIN10':
        return const dpgsql_latin.Latin16Codec();
      case 'ISO88595':
        return const dpgsql_latin.Latin5Codec();
      case 'ISO88596':
        return const dpgsql_latin.Latin6Codec();
      case 'ISO88597':
        return const dpgsql_latin.Latin7Codec();
      case 'ISO88598':
        return const dpgsql_latin.Latin8Codec();
      case 'WIN1250':
        return const dpgsql_windows.Windows1250Codec();
      case 'WIN1251':
        return const dpgsql_windows.Windows1251Codec();
      case 'WIN1252':
        return const dpgsql_windows.Windows1252Codec();
      case 'WIN1253':
        return const dpgsql_windows.Windows1253Codec();
      case 'WIN1254':
        return const dpgsql_windows.Windows1254Codec();
      case 'WIN1256':
        return const dpgsql_windows.Windows1256Codec();
      case 'CP850':
      case 'IBM850':
        return const dpgsql_dos.CodePage850Codec();
      case 'KOI8R':
        return const dpgsql_koi8.Koi8rCodec();
      case 'KOI8U':
        return const dpgsql_koi8.Koi8uCodec();
      case 'BIG5':
        return const dpgsql_big5.Big5Codec();
      case 'GBK':
        return const dpgsql_gbk.GbkCodec();
    }

    throw UnsupportedError(
      'PostgreSQL encoding "$name" is not supported by dpgsql yet. '
      'Supported encodings include UTF8, SQL_ASCII, LATIN1-10, '
      'ISO_8859_5-8, WIN1250-1254, WIN1256, KOI8R, KOI8U, '
      'BIG5 and GBK.',
    );
  }

  static String _postgresEncodingName(String name) {
    switch (_normalizeEncodingName(name)) {
      case 'UTF8':
        return 'UTF8';
      case 'SQLASCII':
        return 'SQL_ASCII';
      case 'ASCII':
        return 'SQL_ASCII';
      case 'LATIN1':
        return 'LATIN1';
      case 'LATIN2':
        return 'LATIN2';
      case 'LATIN3':
        return 'LATIN3';
      case 'LATIN4':
        return 'LATIN4';
      case 'LATIN5':
        return 'LATIN5';
      case 'LATIN6':
        return 'LATIN6';
      case 'LATIN7':
        return 'LATIN7';
      case 'LATIN8':
        return 'LATIN8';
      case 'LATIN9':
        return 'LATIN9';
      case 'LATIN10':
        return 'LATIN10';
      case 'ISO88595':
        return 'ISO_8859_5';
      case 'ISO88596':
        return 'ISO_8859_6';
      case 'ISO88597':
        return 'ISO_8859_7';
      case 'ISO88598':
        return 'ISO_8859_8';
      case 'WIN1250':
        return 'WIN1250';
      case 'WIN1251':
        return 'WIN1251';
      case 'WIN1252':
        return 'WIN1252';
      case 'WIN1253':
        return 'WIN1253';
      case 'WIN1254':
        return 'WIN1254';
      case 'WIN1256':
        return 'WIN1256';
      case 'KOI8R':
        return 'KOI8R';
      case 'KOI8U':
        return 'KOI8U';
      case 'BIG5':
        return 'BIG5';
      case 'GBK':
        return 'GBK';
    }

    throw UnsupportedError(
      'PostgreSQL client encoding "$name" is not supported by dpgsql yet.',
    );
  }

  String get host => _get('Host') ?? 'localhost';
  set host(String value) => _parameters['Host'] = value;

  int get port => int.tryParse(_get('Port') ?? '5432') ?? 5432;
  set port(int value) => _parameters['Port'] = value.toString();

  String get username => _get('Username', 'User ID', 'UserID') ?? 'postgres';
  set username(String value) {
    _parameters['Username'] = value;
    _parameters.remove('User ID');
  }

  String get password => _get('Password') ?? '';
  set password(String value) => _parameters['Password'] = value;

  String get database => _get('Database', 'Initial Catalog') ?? 'postgres';
  set database(String value) => _parameters['Database'] = value;

  SslMode get sslMode {
    final val = _get('SSL Mode', 'SslMode');
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
    return _getBool(
      true,
      'Trust Server Certificate',
      'TrustServerCertificate',
    );
  }

  set trustServerCertificate(bool value) {
    _parameters['Trust Server Certificate'] = value.toString();
  }

  /// Whether pooling is enabled. Mirrors Dpgsql's `Pooling` keyword.
  bool get pooling => _getBool(true, 'Pooling');
  set pooling(bool value) => _parameters['Pooling'] = value.toString();

  /// Minimum number of connections to pre-create when [DpgsqlDataSource.warmup]
  /// is called.
  int get minPoolSize => _getInt(0, 'Minimum Pool Size', 'Min Pool Size');
  set minPoolSize(int value) =>
      _parameters['Minimum Pool Size'] = value.toString();

  /// Maximum number of physical connections allowed in the pool.
  int get maxPoolSize => _getInt(100, 'Maximum Pool Size', 'Max Pool Size');
  set maxPoolSize(int value) =>
      _parameters['Maximum Pool Size'] = value.toString();

  /// Time to wait for a free connection when the pool is exhausted.
  Duration get timeout => Duration(
        seconds: _getInt(15, 'Timeout', 'Connection Timeout'),
      );
  set timeout(Duration value) =>
      _parameters['Timeout'] = value.inSeconds.toString();

  /// How long an idle connector may stay in the pool before being pruned.
  Duration get connectionIdleLifetime => Duration(
        seconds:
            _getInt(300, 'Connection Idle Lifetime', 'ConnectionIdleLifetime'),
      );
  set connectionIdleLifetime(Duration value) =>
      _parameters['Connection Idle Lifetime'] = value.inSeconds.toString();

  /// Maximum physical connector lifetime. Zero disables lifetime pruning.
  Duration get connectionLifetime => Duration(
        seconds: _getInt(3600, 'Connection Lifetime', 'ConnectionLifeTime'),
      );
  set connectionLifetime(Duration value) =>
      _parameters['Connection Lifetime'] = value.inSeconds.toString();

  /// How often the pool prunes idle/lifetime-expired physical connections.
  Duration get connectionPruningInterval => Duration(
        seconds: _getInt(
          10,
          'Connection Pruning Interval',
          'ConnectionPruningInterval',
        ),
      );
  set connectionPruningInterval(Duration value) =>
      _parameters['Connection Pruning Interval'] = value.inSeconds.toString();

  /// Maximum number of automatically prepared statements. Zero disables
  /// automatic preparation, matching Dpgsql's default.
  int get maxAutoPrepare => _getInt(0, 'Max Auto Prepare', 'MaxAutoPrepare');
  set maxAutoPrepare(int value) =>
      _parameters['Max Auto Prepare'] = value.toString();

  /// Number of executions before a statement is automatically prepared.
  int get autoPrepareMinUsages =>
      _getInt(5, 'Auto Prepare Min Usages', 'AutoPrepareMinUsages');
  set autoPrepareMinUsages(int value) =>
      _parameters['Auto Prepare Min Usages'] = value.toString();

  String? operator [](String keyword) => _get(keyword);
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
      final index = part.indexOf('=');
      if (index > 0) {
        final key = part.substring(0, index).trim();
        final value = part.substring(index + 1).trim();
        // Normalize keys if needed, but Dpgsql is case-insensitive usually.
        // We store as provided, but getters handle aliases.
        // Actually, let's store with proper casing or handle in getters.
        // Simple map for now.
        _parameters[key] = value;
      }
    }
  }

  String? _get(String key, [String? alias1, String? alias2]) {
    final aliases = [
      key,
      if (alias1 != null) alias1,
      if (alias2 != null) alias2
    ];
    for (final alias in aliases) {
      final exact = _parameters[alias];
      if (exact != null) {
        return exact;
      }
    }

    for (final entry in _parameters.entries) {
      for (final alias in aliases) {
        if (_normalizeKey(entry.key) == _normalizeKey(alias)) {
          return entry.value;
        }
      }
    }
    return null;
  }

  int _getInt(int fallback, String key, [String? alias1, String? alias2]) {
    final value = int.tryParse(_get(key, alias1, alias2) ?? '');
    return value == null || value < 0 ? fallback : value;
  }

  bool _getBool(
    bool fallback,
    String key, [
    String? alias1,
    String? alias2,
    String? alias3,
  ]) {
    var raw = _get(key, alias1, alias2);
    if (raw == null && alias3 != null) {
      raw = _get(alias3);
    }
    final value = raw?.trim().toLowerCase();
    if (value == null || value.isEmpty) {
      return fallback;
    }
    return const {'1', 'true', 'yes', 'on'}.contains(value);
  }

  static String _normalizeKey(String key) =>
      key.replaceAll(' ', '').replaceAll('_', '').toLowerCase();

  static String _normalizeEncodingName(String value) {
    final normalized = value
        .trim()
        .replaceAll('-', '')
        .replaceAll('_', '')
        .replaceAll(' ', '')
        .toUpperCase();
    if (normalized == 'UNICODE') {
      return 'UTF8';
    }
    if (normalized == 'WINDOWS1250') {
      return 'WIN1250';
    }
    if (normalized == 'WINDOWS1251') {
      return 'WIN1251';
    }
    if (normalized == 'WINDOWS1252') {
      return 'WIN1252';
    }
    if (normalized == 'WINDOWS1253') {
      return 'WIN1253';
    }
    if (normalized == 'WINDOWS1254') {
      return 'WIN1254';
    }
    if (normalized == 'WINDOWS1256') {
      return 'WIN1256';
    }
    return normalized;
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
