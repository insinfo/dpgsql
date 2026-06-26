import 'package:test/test.dart';

import 'test_config.dart';

void main() {
  test('real connection applies LATIN1 client encoding and roundtrips text',
      () async {
    final conn = await openRealConnectionOrSkip(
      options: 'Encoding=LATIN1;Client Encoding=LATIN1',
    );
    if (conn == null) return;

    try {
      expect(
          await executeScalar(conn, 'SHOW client_encoding'), equals('LATIN1'));
      expect(await executeScalar(conn, "SELECT 'Café'::text"), equals('Café'));
    } finally {
      await conn.close();
    }
  });
}
