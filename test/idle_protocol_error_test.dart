// Bytes the driver cannot read, arriving on an idle connection, must lose that
// connection, not the process: there is no caller to receive the error, so it
// used to be an uncaught error.
//
// A fake server on loopback accepts the login and then sends them.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dpgsql/dpgsql.dart';
import 'package:test/test.dart';

List<int> _message(String type, List<int> body) {
  final length = ByteData(4)..setInt32(0, body.length + 4);
  return [type.codeUnitAt(0), ...length.buffer.asUint8List(), ...body];
}

final _loginOk = [
  ..._message('R', [0, 0, 0, 0]),
  ..._message('Z', [0x49]),
];

void main() {
  final cases = <String, List<int>>{
    'a negative message length': [0x53, 0xFF, 0xFF, 0xFF, 0xFF],
    'a length that cannot hold itself': [0x53, 0, 0, 0, 1],
    'an unknown message type': _message('0', [1, 2, 3]),
    'a notification cut in the middle of its fields': _message('A', [1]),
  };

  cases.forEach((name, garbage) {
    test(name, () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((client) {
        var answered = false;
        client.listen((_) {
          if (answered) return;
          answered = true;
          client.add(_loginOk);
          Timer(const Duration(milliseconds: 100), () => client.add(garbage));
        }, onError: (_) {});
      });

      final uncaught = <Object>[];
      final finished = Completer<void>();
      runZonedGuarded(() async {
        final connection = DpgsqlConnection(
            'Host=localhost;Port=${server.port};Database=d;Username=u;'
            'Password=p;Timeout=2;SSL Mode=Disable');
        final lost = connection.onConnectionLost.first;
        try {
          await connection.open();
          await lost.timeout(const Duration(seconds: 3));
          await expectLater(
              connection.createCommand('select 1').executeNonQuery(),
              throwsA(anything));
        } finally {
          await connection.close();
          finished.complete();
        }
      }, (e, s) => uncaught.add(e));
      await finished.future.timeout(const Duration(seconds: 10));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(uncaught, isEmpty);
    });
  });
}
