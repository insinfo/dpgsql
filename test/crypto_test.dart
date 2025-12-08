import 'dart:convert';
import 'dart:typed_data';

import 'package:dpgsql/src/crypto/crypto.dart';
import 'package:test/test.dart';

void main() {
  group('crypto primitives', () {
    test('md5 known vectors', () {
      expect(bytesToHex(md5(utf8.encode(''))),
          equals('d41d8cd98f00b204e9800998ecf8427e'));
      expect(bytesToHex(md5(utf8.encode('abc'))),
          equals('900150983cd24fb0d6963f7d28e17f72'));
    });

    test('sha256 known vectors', () {
      expect(
          bytesToHex(sha256(utf8.encode(''))),
          equals(
              'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'));
      expect(
          bytesToHex(sha256(utf8.encode('abc'))),
          equals(
              'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'));
    });

    test('hmac-sha256 vector', () {
      final key = Uint8List.fromList('key'.codeUnits);
      final message =
          utf8.encode('The quick brown fox jumps over the lazy dog');
      expect(
          bytesToHex(hmacSha256(key, message)),
          equals(
              'f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8'));
    });

    test('pbkdf2-hmac-sha256 vectors', () {
      final password = utf8.encode('password');
      final salt = Uint8List.fromList('salt'.codeUnits);

      expect(
        bytesToHex(pbkdf2HmacSha256(password, salt, 1, 32)),
        equals(
            '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b'),
      );

      expect(
        bytesToHex(pbkdf2HmacSha256(password, salt, 2, 32)),
        equals(
            'ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43'),
      );

      expect(
        bytesToHex(pbkdf2HmacSha256(password, salt, 4096, 32)),
        equals(
            'c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a'),
      );
    });
  });
}
