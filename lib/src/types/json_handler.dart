import 'dart:convert';
import 'dart:typed_data';

import 'oid.dart';
import 'type_handler.dart';

class JsonHandler extends TypeHandler<String> {
  const JsonHandler();

  @override
  int get oid => Oid.json;

  @override
  String read(Uint8List buffer, {bool isText = false}) {
    // JSON binary format is just the UTF8 string (same as text)
    return utf8.decode(buffer);
  }

  @override
  Uint8List write(String value) {
    return utf8.encode(value);
  }
}

class JsonbHandler extends TypeHandler<String> {
  const JsonbHandler();

  @override
  int get oid => Oid.jsonb;

  @override
  String read(Uint8List buffer, {bool isText = false}) {
    if (isText) {
      return utf8.decode(buffer);
    }
    // Binary JSONB: Version (1 byte) + JSON content
    if (buffer.isEmpty) return '';
    final version = buffer[0];
    if (version != 1) {
      throw FormatException('Unknown JSONB version: $version');
    }
    return utf8.decode(buffer.sublist(1));
  }

  @override
  Uint8List write(String value) {
    final bytes = utf8.encode(value);
    final buffer = Uint8List(bytes.length + 1);
    buffer[0] = 1; // Version 1
    buffer.setRange(1, buffer.length, bytes);
    return buffer;
  }
}
