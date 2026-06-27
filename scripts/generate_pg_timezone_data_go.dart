import 'dart:io';
import 'dart:typed_data';

/// Fonte oficial, mantida e constantemente atualizada pela equipe do Golang
/// contendo os arquivos TZif padrão (compilados da IANA).
const String zoneinfoUrl =
    'https://raw.githubusercontent.com/golang/go/master/lib/time/zoneinfo.zip';

const String _defaultOutput =
    'lib/src/utils/pg_timezone/timezone/pg_timezone_data_10y.dart';

// --- Modelos Internos para a Geração ---
class ParsedTimeZone {
  final int offset;
  final bool isDst;
  final String abbreviation;
  ParsedTimeZone(this.offset, this.isDst, this.abbreviation);
}

class ParsedLocation {
  final String name;
  final List<int> transitionAt;
  final List<int> transitionZone;
  final List<ParsedTimeZone> zones;
  ParsedLocation(this.name, this.transitionAt, this.transitionZone, this.zones);
}

Future<void> main(List<String> args) async {
  String outputPath = _defaultOutput;

  for (int i = 0; i < args.length; i++) {
    if (args[i] == '--output' && i + 1 < args.length) {
      outputPath = args[i + 1];
    } else if (args[i] == '-h' || args[i] == '--help') {
      stdout.writeln('Uso: dart run script.dart [--output <caminho>]');
      exit(0);
    }
  }

  stdout.writeln('Baixando banco de dados IANA (zoneinfo) mais recente...');
  final zipBytes = await _download(zoneinfoUrl);

  stdout
      .writeln('Extraindo e decodificando formato binário TZif nativamente...');
  final files = _extractZip(zipBytes);

  final locations = <ParsedLocation>[];

  for (final entry in files.entries) {
    final name = entry.key;
    // Pular diretórios ou arquivos irrelevantes
    if (name.endsWith('/') || !name.contains('/') || name.contains('.')) {
      continue;
    }

    try {
      final loc = _parseTzif(name, entry.value);
      locations.add(loc);
    } catch (e) {
      // Ignorar caso encontre algum arquivo extra que não seja TZif
    }
  }

  // Ordenar as timezones pelo nome (ex: Africa/Abidjan)
  locations.sort((a, b) => a.name.compareTo(b.name));

  final output = File(outputPath);
  if (!await output.parent.exists()) {
    await output.parent.create(recursive: true);
  }

  await output.writeAsString(
    _renderDatabase(locations, sourceDescription: 'Go zoneinfo ($zoneinfoUrl)'),
  );

  stdout.writeln(
    'Sucesso! Gerados ${locations.length} locais de fuso horário em ${output.path}',
  );
}

/// Baixa o arquivo zip na memória sem salvar no disco
Future<Uint8List> _download(String url) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    if (response.statusCode != 200) {
      throw HttpException('Erro no download: HTTP ${response.statusCode}');
    }
    final builder = BytesBuilder();
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return builder.toBytes();
  } finally {
    client.close(force: true);
  }
}

/// Extrator puro Dart para formato ZIP (apenas para ZIPs Descomprimidos/Deflate)
Map<String, Uint8List> _extractZip(Uint8List zipData) {
  final files = <String, Uint8List>{};
  final buffer = ByteData.sublistView(zipData);

  // Procura o Fim do Diretório Central (EOCD)
  int eocdOffset = zipData.length - 22;
  while (eocdOffset >= 0 &&
      buffer.getUint32(eocdOffset, Endian.little) != 0x06054b50) {
    eocdOffset--;
  }
  if (eocdOffset < 0) throw Exception('EOCD não encontrado (ZIP Inválido).');

  final cdOffset = buffer.getUint32(eocdOffset + 16, Endian.little);
  final cdRecords = buffer.getUint16(eocdOffset + 10, Endian.little);

  int offset = cdOffset;
  for (int i = 0; i < cdRecords; i++) {
    if (buffer.getUint32(offset, Endian.little) != 0x02014b50) break;

    final compression = buffer.getUint16(offset + 10, Endian.little);
    final compressedSize = buffer.getUint32(offset + 20, Endian.little);
    final localHeaderOffset = buffer.getUint32(offset + 42, Endian.little);
    final nameLength = buffer.getUint16(offset + 28, Endian.little);
    final extraLength = buffer.getUint16(offset + 30, Endian.little);
    final commentLength = buffer.getUint16(offset + 32, Endian.little);

    final name = String.fromCharCodes(
        zipData.sublist(offset + 46, offset + 46 + nameLength));
    offset += 46 + nameLength + extraLength + commentLength;

    final lhOffset = localHeaderOffset;
    if (buffer.getUint32(lhOffset, Endian.little) == 0x04034b50) {
      final lhNameLength = buffer.getUint16(lhOffset + 26, Endian.little);
      final lhExtraLength = buffer.getUint16(lhOffset + 28, Endian.little);
      final dataOffset = lhOffset + 30 + lhNameLength + lhExtraLength;

      final compressedData =
          zipData.sublist(dataOffset, dataOffset + compressedSize);

      Uint8List? uncompressedData;
      if (compression == 0) {
        // STORE (Sem compressão)
        uncompressedData = compressedData;
      } else if (compression == 8) {
        // DEFLATE
        // ZLibDecoder(raw: true) decodifica fluxos Deflate nativos no Dart
        uncompressedData =
            Uint8List.fromList(ZLibDecoder(raw: true).convert(compressedData));
      }

      if (uncompressedData != null && uncompressedData.length > 4) {
        files[name] = uncompressedData;
      }
    }
  }
  return files;
}

/// Decodificador em puro Dart do Padrão Internacional IANA TZif (RFC 8536)
ParsedLocation _parseTzif(String name, Uint8List data) {
  final buffer = ByteData.sublistView(data);

  // Magic bytes "TZif"
  if (buffer.lengthInBytes < 44 || buffer.getUint32(0) != 0x545A6966) {
    throw Exception('Formato TZif mágico inválido');
  }

  int offset = 44;
  int tzh_ttisgmtcnt = buffer.getInt32(20);
  int tzh_ttisstdcnt = buffer.getInt32(24);
  int tzh_leapcnt = buffer.getInt32(28);
  int tzh_timecnt = buffer.getInt32(32);
  int tzh_typecnt = buffer.getInt32(36);
  int tzh_charcnt = buffer.getInt32(40);

  // Calcula onde o bloco V1 acaba
  int v1End = 44 +
      tzh_timecnt * 4 +
      tzh_timecnt * 1 +
      tzh_typecnt * 6 +
      tzh_charcnt * 1 +
      tzh_leapcnt * 8 +
      tzh_ttisstdcnt * 1 +
      tzh_ttisgmtcnt * 1;

  int v2Version = data[4];
  // Se possuir formato moderno (V2/V3) suporta timestamps 64-bit
  bool useV2 = (v2Version == 0x32 || v2Version == 0x33) &&
      v1End + 44 <= buffer.lengthInBytes &&
      buffer.getUint32(v1End) == 0x545A6966;

  if (useV2) {
    offset = v1End + 20;
    tzh_ttisgmtcnt = buffer.getInt32(offset);
    offset += 4;
    tzh_ttisstdcnt = buffer.getInt32(offset);
    offset += 4;
    tzh_leapcnt = buffer.getInt32(offset);
    offset += 4;
    tzh_timecnt = buffer.getInt32(offset);
    offset += 4;
    tzh_typecnt = buffer.getInt32(offset);
    offset += 4;
    tzh_charcnt = buffer.getInt32(offset);
    offset += 4;
  } else {
    offset = 44;
  }

  List<int> transAt = [];
  for (int i = 0; i < tzh_timecnt; i++) {
    if (useV2) {
      transAt.add(buffer.getInt64(offset) * 1000);
      offset += 8;
    } else {
      transAt.add(buffer.getInt32(offset) * 1000);
      offset += 4;
    }
  }

  List<int> transZone = [];
  for (int i = 0; i < tzh_timecnt; i++) {
    transZone.add(buffer.getUint8(offset));
    offset += 1;
  }

  List<int> ttisgmtoff = [];
  List<int> ttisdst = [];
  List<int> tznameIndex = [];
  for (int i = 0; i < tzh_typecnt; i++) {
    ttisgmtoff.add(buffer.getInt32(offset));
    offset += 4;
    ttisdst.add(buffer.getUint8(offset));
    offset += 1;
    tznameIndex.add(buffer.getUint8(offset));
    offset += 1;
  }

  String chars =
      String.fromCharCodes(data.sublist(offset, offset + tzh_charcnt));

  int defaultZone = 0;
  for (int i = 0; i < tzh_typecnt; i++) {
    if (ttisdst[i] == 0) {
      defaultZone = i;
      break;
    }
  }

  // Insere a âncora inicial do pacote Dart (equivalente ao pacote original)
  List<int> finalTransAt = [-8640000000000000];
  List<int> finalTransZone = [defaultZone];
  finalTransAt.addAll(transAt);
  finalTransZone.addAll(transZone);

  List<ParsedTimeZone> zones = [];
  for (int i = 0; i < tzh_typecnt; i++) {
    int idx = tznameIndex[i];
    int endIdx = chars.indexOf('\x00', idx);
    if (endIdx == -1) endIdx = chars.length;
    zones.add(ParsedTimeZone(
      ttisgmtoff[i] * 1000,
      ttisdst[i] == 1,
      chars.substring(idx, endIdx),
    ));
  }

  return ParsedLocation(name, finalTransAt, finalTransZone, zones);
}

String _renderDatabase(
  List<ParsedLocation> locations, {
  required String sourceDescription,
}) {
  final buffer = StringBuffer()
    ..writeln('// Generated by standalone generator script.')
    ..writeln('// Source: $sourceDescription')
    ..writeln('// Do not edit by hand.')
    ..writeln()
    ..writeln("import '../timezone.dart';")
    ..writeln()
    ..writeln('final pgDatabaseMap = <String, Location>{');

  for (final location in locations) {
    buffer
      ..write('  ')
      ..write(_quote(location.name))
      ..writeln(': Location(')
      ..write('    ')
      ..write(_quote(location.name))
      ..writeln(',')
      ..writeln('    ${_intList(location.transitionAt)},')
      ..writeln('    ${_intList(location.transitionZone)},')
      ..writeln('    <TimeZone>[');

    for (final zone in location.zones) {
      buffer
        ..write('      TimeZone(')
        ..write(zone.offset)
        ..write(', isDst: ')
        ..write(zone.isDst)
        ..write(', abbreviation: ')
        ..write(_quote(zone.abbreviation))
        ..writeln('),');
    }

    buffer
      ..writeln('    ],')
      ..writeln('  ),');
  }
  buffer.writeln('};');
  return buffer.toString();
}

String _intList(List<int> values) => '<int>[${values.join(', ')}]';

String _quote(String value) {
  final escaped = value.replaceAll('\\', '\\\\').replaceAll("'", "\\'");
  return "'$escaped'";
}
