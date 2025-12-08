import 'dart:typed_data';

const List<int> _md5S = <int>[
  7,
  12,
  17,
  22,
  7,
  12,
  17,
  22,
  7,
  12,
  17,
  22,
  7,
  12,
  17,
  22,
  5,
  9,
  14,
  20,
  5,
  9,
  14,
  20,
  5,
  9,
  14,
  20,
  5,
  9,
  14,
  20,
  4,
  11,
  16,
  23,
  4,
  11,
  16,
  23,
  4,
  11,
  16,
  23,
  4,
  11,
  16,
  23,
  6,
  10,
  15,
  21,
  6,
  10,
  15,
  21,
  6,
  10,
  15,
  21,
  6,
  10,
  15,
  21,
];

const List<int> _md5K = <int>[
  0xd76aa478,
  0xe8c7b756,
  0x242070db,
  0xc1bdceee,
  0xf57c0faf,
  0x4787c62a,
  0xa8304613,
  0xfd469501,
  0x698098d8,
  0x8b44f7af,
  0xffff5bb1,
  0x895cd7be,
  0x6b901122,
  0xfd987193,
  0xa679438e,
  0x49b40821,
  0xf61e2562,
  0xc040b340,
  0x265e5a51,
  0xe9b6c7aa,
  0xd62f105d,
  0x02441453,
  0xd8a1e681,
  0xe7d3fbc8,
  0x21e1cde6,
  0xc33707d6,
  0xf4d50d87,
  0x455a14ed,
  0xa9e3e905,
  0xfcefa3f8,
  0x676f02d9,
  0x8d2a4c8a,
  0xfffa3942,
  0x8771f681,
  0x6d9d6122,
  0xfde5380c,
  0xa4beea44,
  0x4bdecfa9,
  0xf6bb4b60,
  0xbebfbc70,
  0x289b7ec6,
  0xeaa127fa,
  0xd4ef3085,
  0x04881d05,
  0xd9d4d039,
  0xe6db99e5,
  0x1fa27cf8,
  0xc4ac5665,
  0xf4292244,
  0x432aff97,
  0xab9423a7,
  0xfc93a039,
  0x655b59c3,
  0x8f0ccc92,
  0xffeff47d,
  0x85845dd1,
  0x6fa87e4f,
  0xfe2ce6e0,
  0xa3014314,
  0x4e0811a1,
  0xf7537e82,
  0xbd3af235,
  0x2ad7d2bb,
  0xeb86d391,
];

const List<int> _sha256K = <int>[
  0x428a2f98,
  0x71374491,
  0xb5c0fbcf,
  0xe9b5dba5,
  0x3956c25b,
  0x59f111f1,
  0x923f82a4,
  0xab1c5ed5,
  0xd807aa98,
  0x12835b01,
  0x243185be,
  0x550c7dc3,
  0x72be5d74,
  0x80deb1fe,
  0x9bdc06a7,
  0xc19bf174,
  0xe49b69c1,
  0xefbe4786,
  0x0fc19dc6,
  0x240ca1cc,
  0x2de92c6f,
  0x4a7484aa,
  0x5cb0a9dc,
  0x76f988da,
  0x983e5152,
  0xa831c66d,
  0xb00327c8,
  0xbf597fc7,
  0xc6e00bf3,
  0xd5a79147,
  0x06ca6351,
  0x14292967,
  0x27b70a85,
  0x2e1b2138,
  0x4d2c6dfc,
  0x53380d13,
  0x650a7354,
  0x766a0abb,
  0x81c2c92e,
  0x92722c85,
  0xa2bfe8a1,
  0xa81a664b,
  0xc24b8b70,
  0xc76c51a3,
  0xd192e819,
  0xd6990624,
  0xf40e3585,
  0x106aa070,
  0x19a4c116,
  0x1e376c08,
  0x2748774c,
  0x34b0bcb5,
  0x391c0cb3,
  0x4ed8aa4a,
  0x5b9cca4f,
  0x682e6ff3,
  0x748f82ee,
  0x78a5636f,
  0x84c87814,
  0x8cc70208,
  0x90befffa,
  0xa4506ceb,
  0xbef9a3f7,
  0xc67178f2,
];

int _rotl32(int x, int n) => ((x << n) | (x >> (32 - n))) & 0xFFFFFFFF;

int _rotr32(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xFFFFFFFF;

void _writeUint32LE(Uint8List buffer, int offset, int value) {
  buffer[offset] = value & 0xFF;
  buffer[offset + 1] = (value >> 8) & 0xFF;
  buffer[offset + 2] = (value >> 16) & 0xFF;
  buffer[offset + 3] = (value >> 24) & 0xFF;
}

void _writeUint32BE(Uint8List buffer, int offset, int value) {
  buffer[offset] = (value >> 24) & 0xFF;
  buffer[offset + 1] = (value >> 16) & 0xFF;
  buffer[offset + 2] = (value >> 8) & 0xFF;
  buffer[offset + 3] = value & 0xFF;
}

Uint8List md5(List<int> data) {
  final message = Uint8List.fromList(data);
  final originalLength = message.length;
  final paddingLength = ((56 - ((originalLength + 1) % 64)) + 64) % 64;
  final totalLength = originalLength + 1 + paddingLength + 8;
  final buffer = Uint8List(totalLength);
  buffer.setRange(0, originalLength, message);
  buffer[originalLength] = 0x80;

  final bitLength = originalLength * 8;
  for (var i = 0; i < 8; i++) {
    buffer[totalLength - 8 + i] = (bitLength >> (8 * i)) & 0xFF;
  }

  var a0 = 0x67452301;
  var b0 = 0xEFCDAB89;
  var c0 = 0x98BADCFE;
  var d0 = 0x10325476;

  for (var offset = 0; offset < totalLength; offset += 64) {
    final m = List<int>.filled(16, 0);
    for (var i = 0; i < 16; i++) {
      final j = offset + i * 4;
      m[i] = buffer[j] |
          (buffer[j + 1] << 8) |
          (buffer[j + 2] << 16) |
          (buffer[j + 3] << 24);
    }

    var a = a0;
    var b = b0;
    var c = c0;
    var d = d0;

    for (var i = 0; i < 64; i++) {
      int f;
      int g;
      if (i < 16) {
        f = (b & c) | ((~b) & d);
        g = i;
      } else if (i < 32) {
        f = (d & b) | ((~d) & c);
        g = (5 * i + 1) % 16;
      } else if (i < 48) {
        f = b ^ c ^ d;
        g = (3 * i + 5) % 16;
      } else {
        f = c ^ (b | (~d));
        g = (7 * i) % 16;
      }

      final tmp = d;
      d = c;
      c = b;
      final int sum = (a + f + _md5K[i] + m[g]) & 0xFFFFFFFF;
      b = (b + _rotl32(sum, _md5S[i])) & 0xFFFFFFFF;
      a = tmp;
    }

    a0 = (a0 + a) & 0xFFFFFFFF;
    b0 = (b0 + b) & 0xFFFFFFFF;
    c0 = (c0 + c) & 0xFFFFFFFF;
    d0 = (d0 + d) & 0xFFFFFFFF;
  }

  final out = Uint8List(16);
  _writeUint32LE(out, 0, a0);
  _writeUint32LE(out, 4, b0);
  _writeUint32LE(out, 8, c0);
  _writeUint32LE(out, 12, d0);
  return out;
}

Uint8List sha256(List<int> data) {
  final message = Uint8List.fromList(data);
  final length = message.length;
  final paddingLength = ((56 - ((length + 1) % 64)) + 64) % 64;
  final totalLength = length + 1 + paddingLength + 8;
  final buffer = Uint8List(totalLength);
  buffer.setRange(0, length, message);
  buffer[length] = 0x80;

  final bitLength = length * 8;
  for (var i = 0; i < 8; i++) {
    buffer[totalLength - 1 - i] = (bitLength >> (8 * i)) & 0xFF;
  }

  var h0 = 0x6A09E667;
  var h1 = 0xBB67AE85;
  var h2 = 0x3C6EF372;
  var h3 = 0xA54FF53A;
  var h4 = 0x510E527F;
  var h5 = 0x9B05688C;
  var h6 = 0x1F83D9AB;
  var h7 = 0x5BE0CD19;

  final w = List<int>.filled(64, 0);

  for (var offset = 0; offset < totalLength; offset += 64) {
    for (var i = 0; i < 16; i++) {
      final j = offset + i * 4;
      w[i] = (buffer[j] << 24) |
          (buffer[j + 1] << 16) |
          (buffer[j + 2] << 8) |
          buffer[j + 3];
    }

    for (var i = 16; i < 64; i++) {
      final int s0 =
          _rotr32(w[i - 15], 7) ^ _rotr32(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final int s1 =
          _rotr32(w[i - 2], 17) ^ _rotr32(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xFFFFFFFF;
    }

    var a = h0;
    var b = h1;
    var c = h2;
    var d = h3;
    var e = h4;
    var f = h5;
    var g = h6;
    var h = h7;

    for (var i = 0; i < 64; i++) {
      final int s1 =
          (_rotr32(e, 6) ^ _rotr32(e, 11) ^ _rotr32(e, 25)) & 0xFFFFFFFF;
      final int ch = ((e & f) ^ ((~e) & g)) & 0xFFFFFFFF;
      final int temp1 = (h + s1 + ch + _sha256K[i] + w[i]) & 0xFFFFFFFF;
      final int s0 =
          (_rotr32(a, 2) ^ _rotr32(a, 13) ^ _rotr32(a, 22)) & 0xFFFFFFFF;
      final int maj = ((a & b) ^ (a & c) ^ (b & c)) & 0xFFFFFFFF;
      final int temp2 = (s0 + maj) & 0xFFFFFFFF;

      h = g;
      g = f;
      f = e;
      e = (d + temp1) & 0xFFFFFFFF;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & 0xFFFFFFFF;
    }

    h0 = (h0 + a) & 0xFFFFFFFF;
    h1 = (h1 + b) & 0xFFFFFFFF;
    h2 = (h2 + c) & 0xFFFFFFFF;
    h3 = (h3 + d) & 0xFFFFFFFF;
    h4 = (h4 + e) & 0xFFFFFFFF;
    h5 = (h5 + f) & 0xFFFFFFFF;
    h6 = (h6 + g) & 0xFFFFFFFF;
    h7 = (h7 + h) & 0xFFFFFFFF;
  }

  final out = Uint8List(32);
  _writeUint32BE(out, 0, h0);
  _writeUint32BE(out, 4, h1);
  _writeUint32BE(out, 8, h2);
  _writeUint32BE(out, 12, h3);
  _writeUint32BE(out, 16, h4);
  _writeUint32BE(out, 20, h5);
  _writeUint32BE(out, 24, h6);
  _writeUint32BE(out, 28, h7);
  return out;
}

Uint8List hmacSha256(Uint8List key, List<int> data) {
  const blockSize = 64;
  Uint8List actualKey;
  if (key.length > blockSize) {
    actualKey = sha256(key);
  } else {
    actualKey = Uint8List(blockSize);
    actualKey.setRange(0, key.length, key);
  }

  final ipad = Uint8List(blockSize);
  final opad = Uint8List(blockSize);
  for (var i = 0; i < blockSize; i++) {
    final b = actualKey[i];
    ipad[i] = b ^ 0x36;
    opad[i] = b ^ 0x5C;
  }

  final messageBytes = Uint8List.fromList(data);
  final inner = Uint8List(blockSize + messageBytes.length);
  inner.setRange(0, blockSize, ipad);
  inner.setRange(blockSize, blockSize + messageBytes.length, messageBytes);
  final innerHash = sha256(inner);

  final outer = Uint8List(blockSize + innerHash.length);
  outer.setRange(0, blockSize, opad);
  outer.setRange(blockSize, blockSize + innerHash.length, innerHash);
  return sha256(outer);
}

Uint8List pbkdf2HmacSha256(
    List<int> password, Uint8List salt, int iterations, int length) {
  if (iterations <= 0) {
    throw ArgumentError.value(iterations, 'iterations', 'Must be > 0');
  }
  if (length <= 0) {
    throw ArgumentError.value(length, 'length', 'Must be > 0');
  }

  final passwordBytes = Uint8List.fromList(password);
  final blockCount = (length + 31) ~/ 32;
  final output = Uint8List(blockCount * 32);

  for (var blockIndex = 1; blockIndex <= blockCount; blockIndex++) {
    final saltBlock = Uint8List(salt.length + 4);
    saltBlock.setRange(0, salt.length, salt);
    saltBlock[salt.length + 0] = (blockIndex >> 24) & 0xFF;
    saltBlock[salt.length + 1] = (blockIndex >> 16) & 0xFF;
    saltBlock[salt.length + 2] = (blockIndex >> 8) & 0xFF;
    saltBlock[salt.length + 3] = blockIndex & 0xFF;

    var u = hmacSha256(passwordBytes, saltBlock);
    final blockResult = Uint8List.fromList(u);

    for (var i = 1; i < iterations; i++) {
      u = hmacSha256(passwordBytes, u);
      for (var j = 0; j < blockResult.length; j++) {
        blockResult[j] ^= u[j];
      }
    }

    final start = (blockIndex - 1) * 32;
    output.setRange(start, start + 32, blockResult);
  }

  return Uint8List.sublistView(output, 0, length);
}

String bytesToHex(List<int> bytes) {
  final buffer = StringBuffer();
  for (final b in bytes) {
    buffer.write((b & 0xFF).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}
