import 'dart:io';
import 'dart:async';

void main() async {
  final server = await ServerSocket.bind('localhost', 0);
  server.listen((client) {
    client.add([83]); // 'S'
    // Don't close, keep open
  });

  final socket = await Socket.connect('localhost', server.port);
  final completer = Completer();
  final sub = socket.listen((data) {
    print('Got: $data');
    completer.complete();
  });

  await completer.future;
  await sub.cancel();

  try {
    await SecureSocket.secure(socket, onBadCertificate: (_) => true);
    print('Secure success');
  } catch (e) {
    print('Secure failed: $e');
  }

  await socket.close();
  await server.close();
}
