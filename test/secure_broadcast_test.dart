import 'dart:io';
import 'dart:async';

void main() async {
  final server = await ServerSocket.bind('localhost', 0);
  server.listen((client) {
    client.add([83]);
  });

  final socket = await Socket.connect('localhost', server.port);
  final broadcast = socket.asBroadcastStream();

  final completer = Completer();
  final sub = broadcast.listen((data) {
    print('Got: $data');
    completer.complete();
  });

  await completer.future;
  await sub.cancel();

  // Now try secure
  try {
    await SecureSocket.secure(socket, onBadCertificate: (_) => true);
    print('Secure success');
  } catch (e) {
    print('Secure failed: $e');
  }

  await socket.close();
  await server.close();
}
