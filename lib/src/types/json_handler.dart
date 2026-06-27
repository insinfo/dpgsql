import 'dart:convert';
import 'dart:typed_data';

import 'oid.dart';
import 'type_handler.dart';

class JsonHandler extends TypeHandler<dynamic> {
  const JsonHandler({this.decodeAsString = false});

  final bool decodeAsString;

  @override
  int get oid => Oid.json;

  @override
  Object? read(Uint8List buffer,
      {bool isText = false, Encoding encoding = utf8}) {
    final text = encoding.decode(buffer);
    return decodeAsString ? text : json.decode(text);
  }

  @override
  Uint8List write(dynamic value, {Encoding encoding = utf8}) {
    final text = value is String ? value : json.encode(value);
    return Uint8List.fromList(encoding.encode(text));
  }
}

class JsonbHandler extends TypeHandler<dynamic> {
  const JsonbHandler({this.decodeAsString = false});

  final bool decodeAsString;

  @override
  int get oid => Oid.jsonb;

  @override
  Object? read(Uint8List buffer,
      {bool isText = false, Encoding encoding = utf8}) {
    late final String text;
    if (isText) {
      text = encoding.decode(buffer);
      return decodeAsString ? text : json.decode(text);
    }
    // Binary JSONB: Version (1 byte) + JSON content
    if (buffer.isEmpty) return decodeAsString ? '' : null;
    final version = buffer[0];
    if (version != 1) {
      throw FormatException('Unknown JSONB version: $version');
    }
    text = encoding.decode(Uint8List.sublistView(buffer, 1));
    return decodeAsString ? text : json.decode(text);
  }

  @override
  Uint8List write(dynamic value, {Encoding encoding = utf8}) {
    final text = value is String ? value : json.encode(value);
    final bytes = encoding.encode(text);
    final buffer = Uint8List(bytes.length + 1);
    buffer[0] = 1; // Version 1
    buffer.setRange(1, buffer.length, bytes);
    return buffer;
  }
}
