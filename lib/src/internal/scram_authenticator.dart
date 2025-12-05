import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

class ScramSha256Authenticator {
  ScramSha256Authenticator(this.username, this.password);

  final String username;
  final String password;

  late String _clientNonce;
  late String _clientFirstMessageBare;

  // Step 1: Client Initial Response
  String createInitialResponse() {
    _clientNonce = _generateNonce();
    // GS2 Header: n,, (no channel binding)
    // Attribute 'n' is username (SaslPrep'd, but we assume simple ascii/utf8 for now)
    // Attribute 'r' is nonce
    _clientFirstMessageBare = 'n=$username,r=$_clientNonce';

    // Message = gs2-header + client-first-message-bare
    return 'n,,$_clientFirstMessageBare';
  }

  // Step 2: Handle Server Challenge (Continue)
  String handleContinue(String serverFirstMessage) {
    // Parser server message: r=...,s=...,i=...
    final parts = _parseMap(serverFirstMessage);
    final r = parts['r'];
    final s = parts['s'];
    final i = int.tryParse(parts['i'] ?? '');

    if (r == null || s == null || i == null) {
      throw Exception('Invalid SCRAM server message: $serverFirstMessage');
    }

    if (!r.startsWith(_clientNonce)) {
      throw Exception('Server nonce does not match client nonce');
    }

    final salt = base64.decode(s);
    final iterations = i;

    // Compute SaltedPassword
    final saltedPassword = _hi(password, salt, iterations);

    // ClientKey = HMAC(SaltedPassword, "Client Key")
    final clientKey = _hmac(saltedPassword, 'Client Key');

    // StoredKey = H(ClientKey)
    final storedKey = _h(clientKey);

    // AuthMessage = client-first-message-bare + "," + server-first-message + "," + client-final-message-without-proof
    // client-final-message-without-proof = c=biws,r=nonce
    final channelBinding = 'c=biws'; // base64("n,,")
    final clientFinalMessageWithoutProof = '$channelBinding,r=$r';

    final authMessage =
        '$_clientFirstMessageBare,$serverFirstMessage,$clientFinalMessageWithoutProof';

    // ClientSignature = HMAC(StoredKey, AuthMessage)
    final clientSignature = _hmac(storedKey, authMessage);

    // ClientProof = ClientKey XOR ClientSignature
    final clientProof = _xor(clientKey, clientSignature);
    final proofBase64 = base64.encode(clientProof);

    // Final Message: client-final-message-without-proof + ",p=" + proofBase64
    return '$clientFinalMessageWithoutProof,p=$proofBase64';
  }

  // Helpers

  String _generateNonce() {
    final rand = Random.secure();
    final bytes = Uint8List(24); // 24 bytes -> ~32 chars base64
    for (var i = 0; i < 24; i++) bytes[i] = rand.nextInt(256);
    return base64.encode(bytes);
  }

  Map<String, String> _parseMap(String message) {
    final map = <String, String>{};
    final parts = message.split(',');
    for (final part in parts) {
      final idx = part.indexOf('=');
      if (idx != -1) {
        final key = part.substring(0, idx);
        final value = part.substring(idx + 1);
        map[key] = value;
      }
    }
    return map;
  }

  Uint8List _hi(String password, Uint8List salt, int iterations) {
    // PBKDF2 with HMAC-SHA256
    final mac = HMac(SHA256Digest(), 64);
    final pkcs = PBKDF2KeyDerivator(mac)
      ..init(Pbkdf2Parameters(salt, iterations, 32)); // 32 bytes for SHA256

    return pkcs.process(utf8.encode(password));
  }

  Uint8List _hmac(Uint8List key, String data) {
    final hmac = HMac(SHA256Digest(), 64)..init(KeyParameter(key));
    return hmac.process(utf8.encode(data));
  }

  Uint8List _h(Uint8List data) {
    final digest = SHA256Digest();
    return digest.process(data);
  }

  Uint8List _xor(Uint8List a, Uint8List b) {
    final res = Uint8List(a.length);
    for (var i = 0; i < a.length; i++) {
      res[i] = a[i] ^ b[i];
    }
    return res;
  }
}
