import 'dart:typed_data';

/// Pool simples de [Uint8List] com tamanhos arredondados para potências de dois.
///
/// Objetivo: reduzir pressões de alocação para buffers transitórios do driver.
/// Não há garantia de isolamento entre locatários; consumidores devem copiar os
/// dados caso precisem manter referências a longo prazo.
class Uint8ListPool {
  Uint8ListPool._();

  static const int _maxBucketSize = 8;
  static final Map<int, List<Uint8List>> _buckets = <int, List<Uint8List>>{};

  /// Obtém um buffer com capacidade >= [minimumLength].
  static Uint8List rent(int minimumLength) {
    if (minimumLength <= 0) {
      return Uint8List(0);
    }

    final bucketSize = _nextPowerOfTwo(minimumLength);
    final bucket = _buckets[bucketSize];
    if (bucket != null && bucket.isNotEmpty) {
      return bucket.removeLast();
    }

    return Uint8List(bucketSize);
  }

  /// Devolve um [buffer] ao pool.
  static void release(Uint8List buffer) {
    if (buffer.isEmpty) {
      return;
    }

    final bucketSize = _nextPowerOfTwo(buffer.length);
    final bucket = _buckets.putIfAbsent(bucketSize, () => <Uint8List>[]);
    if (bucket.length >= _maxBucketSize) {
      return;
    }
    bucket.add(buffer);
  }

  static int _nextPowerOfTwo(int value) {
    if (value <= 1) {
      return 1;
    }
    var v = value - 1;
    v |= v >> 1;
    v |= v >> 2;
    v |= v >> 4;
    v |= v >> 8;
    v |= v >> 16;
    v |= v >> 32;
    return v + 1;
  }
}
