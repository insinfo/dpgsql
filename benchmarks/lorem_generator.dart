import 'dart:math';

class LoremGenerator {
  static final _random = Random();

  static const _words = [
    'lorem',
    'ipsum',
    'dolor',
    'sit',
    'amet',
    'consectetur',
    'adipiscing',
    'elit',
    'sed',
    'do',
    'eiusmod',
    'tempor',
    'incididunt',
    'ut',
    'labore',
    'et',
    'dolore',
    'magna',
    'aliqua',
    'enim',
    'ad',
    'minim',
    'veniam',
    'quis',
    'nostrud',
    'exercitation',
    'ullamco',
    'laboris',
    'nisi',
    'aliquip',
    'ex',
    'ea',
    'commodo',
    'consequat',
    'duis',
    'aute',
    'irure',
    'in',
    'reprehenderit',
    'voluptate',
    'velit',
    'esse',
    'cillum',
    'fugiat',
    'nulla',
    'pariatur',
    'excepteur',
    'sint',
    'occaecat',
    'cupidatat',
    'non',
    'proident',
    'sunt',
    'culpa',
    'qui',
    'officia',
    'deserunt',
    'mollit',
    'anim',
    'id',
    'est',
    'laborum',
    'vitae',
    'suscipit',
    'tellus',
    'mauris',
    'pharetra',
    'massa',
    'ultricies',
    'integer',
    'malesuada',
    'fames',
    'turpis',
    'egestas',
    'pretium',
    'vulputate',
    'sapien',
    'nec',
    'sagittis',
    'aliquam',
    'eleifend',
    'donec',
    'condimentum',
    'mattis',
    'pellentesque',
    'diam',
    'volutpat',
    'commodo',
    'blandit',
    'libero',
    'venenatis',
    'cras',
    'pulvinar',
    'mattis',
    'nunc',
    'sed',
    'blandit',
    'velit',
    'viverra',
    'justo',
    'nec',
    'ultrices'
  ];

  /// Gera uma palavra aleatória
  static String word() {
    return _words[_random.nextInt(_words.length)];
  }

  /// Gera uma sentença com número variável de palavras
  static String sentence({int minWords = 5, int maxWords = 15}) {
    final wordCount = minWords + _random.nextInt(maxWords - minWords + 1);
    final words = List.generate(wordCount, (_) => word());
    words[0] = words[0][0].toUpperCase() + words[0].substring(1);
    return '${words.join(' ')}.';
  }

  /// Gera um parágrafo com número variável de sentenças
  static String paragraph({int minSentences = 3, int maxSentences = 7}) {
    final sentenceCount =
        minSentences + _random.nextInt(maxSentences - minSentences + 1);
    final sentences = List.generate(sentenceCount, (_) => sentence());
    return sentences.join(' ');
  }

  /// Gera múltiplos parágrafos
  static String paragraphs(int count) {
    return List.generate(count, (_) => paragraph()).join('\n\n');
  }

  /// Gera um título curto
  static String title({int minWords = 2, int maxWords = 5}) {
    final wordCount = minWords + _random.nextInt(maxWords - minWords + 1);
    final words = List.generate(wordCount, (_) => word());
    return words.map((w) => w[0].toUpperCase() + w.substring(1)).join(' ');
  }

  /// Gera um email fictício
  static String email() {
    final name = word();
    final domain = word();
    final tld = ['com', 'org', 'net', 'io'][_random.nextInt(4)];
    return '$name@$domain.$tld';
  }

  /// Gera um nome de pessoa
  static String name() {
    final firstName = word()[0].toUpperCase() + word().substring(1);
    final lastName = word()[0].toUpperCase() + word().substring(1);
    return '$firstName $lastName';
  }

  /// Gera um número inteiro aleatório
  static int integer({int min = 0, int max = 100000}) {
    return min + _random.nextInt(max - min + 1);
  }

  /// Gera um número decimal aleatório
  static double decimal({double min = 0.0, double max = 1000.0}) {
    return min + _random.nextDouble() * (max - min);
  }

  /// Gera uma data aleatória nos últimos anos
  static DateTime date({int yearsBack = 5}) {
    final now = DateTime.now();
    final daysBack = _random.nextInt(yearsBack * 365);
    return now.subtract(Duration(days: daysBack));
  }

  /// Gera um booleano aleatório
  static bool boolean() {
    return _random.nextBool();
  }
}
