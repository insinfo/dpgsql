import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln(
      'Uso: dart run benchmarks/compare_benchmarks.dart <a.json> <b.json> [c.json ...]',
    );
    exitCode = 64;
    return;
  }

  final benchmarks = <Map<String, dynamic>>[
    for (final path in args)
      jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>,
  ];

  stdout.writeln(_environmentSummary(benchmarks));
  stdout.writeln();
  stdout.writeln(_scalarTable(benchmarks));
  stdout.writeln();
  stdout.writeln(_resultSetTable(
    benchmarks,
    title: 'Result set drain (read rows, no value access)',
    resultSetKey: 'result_sets_drain',
  ));
  stdout.writeln();
  stdout.writeln(_resultSetTable(
    benchmarks,
    title: 'Result set simple (id/name/payload)',
    resultSetKey: 'result_sets_simple',
  ));
  stdout.writeln();
  stdout.writeln(_resultSetTable(
    benchmarks,
    title: 'Result set maps (ORM-style Map<String, dynamic>)',
    resultSetKey: 'result_sets_maps',
  ));
  stdout.writeln();
  stdout.writeln(_resultSetTable(
    benchmarks,
    title: 'Result set maps rawText (PHP-style String/null)',
    resultSetKey: 'result_sets_maps_raw_text',
  ));
  stdout.writeln();
  stdout.writeln(_resultSetTable(
    benchmarks,
    title: 'Application typed class + JSON serialization',
    resultSetKey: 'application_typed_json',
  ));
  stdout.writeln();
  stdout.writeln(_resultSetTable(
    benchmarks,
    title: 'Result set full (id/name/numeric/timestamp/payload)',
    resultSetKey: 'result_sets',
  ));
}

String _environmentSummary(List<Map<String, dynamic>> benchmarks) {
  final first = benchmarks.first;
  final server = first['server'] as Map<String, dynamic>? ?? {};
  return [
    'Environment:',
    '- host: `${first['host']}`',
    '- port: `${first['port']}`',
    '- database: `${first['database']}`',
    '- secure: `${first['secure']}`',
    '- server: `${server['server_version_num'] ?? server['version'] ?? '-'}`',
    '- connect_mode: `${first['connect_mode']}`',
  ].join('\n');
}

String _scalarTable(List<Map<String, dynamic>> benchmarks) {
  final rows = <String>[
    '| Métrica | ${benchmarks.map((b) => b['driver']).join(' | ')} |',
    '|---|${List.filled(benchmarks.length, '---:').join('|')}|',
  ];

  const metrics = <MapEntry<String, String>>[
    MapEntry('connect_avg_ms', 'Connect avg ms'),
    MapEntry('text_avg_ms', 'SELECT 1 avg ms'),
    MapEntry('text_ops_per_sec', 'SELECT 1 ops/s'),
    MapEntry('parameter_avg_ms', 'Param avg ms'),
    MapEntry('parameter_ops_per_sec', 'Param ops/s'),
    MapEntry('prepared_avg_ms', 'Prepared avg ms'),
    MapEntry('prepared_ops_per_sec', 'Prepared ops/s'),
  ];

  for (final metric in metrics) {
    final values = benchmarks
        .map((benchmark) => _formatMetric(benchmark[metric.key]))
        .join(' | ');
    rows.add('| ${metric.value} | $values |');
  }

  return rows.join('\n');
}

String _resultSetTable(
  List<Map<String, dynamic>> benchmarks, {
  required String title,
  required String resultSetKey,
}) {
  final resultSetKeys = benchmarks
      .expand((b) => ((b[resultSetKey] as Map<String, dynamic>?) ?? {}).keys)
      .toSet()
      .toList()
    ..sort((a, b) => _rowsFromKey(a).compareTo(_rowsFromKey(b)));

  final rows = <String>[
    '| $title | ${benchmarks.map((b) => b['driver']).join(' | ')} |',
    '|---|${List.filled(benchmarks.length, '---:').join('|')}|',
  ];

  for (final key in resultSetKeys) {
    for (final metric in const <MapEntry<String, String>>[
      MapEntry('avg_ms', 'avg ms'),
      MapEntry('queries_per_sec', 'queries/s'),
      MapEntry('rows_per_sec', 'rows/s'),
    ]) {
      final values = benchmarks.map((benchmark) {
        final resultSets = benchmark[resultSetKey] as Map<String, dynamic>?;
        final entry = resultSets?[key] as Map<String, dynamic>?;
        return _formatMetric(entry?[metric.key]);
      }).join(' | ');
      rows.add('| $key ${metric.value} | $values |');
    }
  }

  return rows.join('\n');
}

int _rowsFromKey(String key) {
  return int.tryParse(key.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
}

String _formatMetric(dynamic value) {
  if (value == null) {
    return '-';
  }
  if (value is num) {
    return value.toStringAsFixed(3);
  }
  return '$value';
}
