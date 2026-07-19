import 'dart:io';

import 'package:dart_frog/dart_frog.dart';

Future<HttpServer> run(Handler handler, InternetAddress ip, int port) {
  final publicDir = Directory('public');

  // لو public/ مش موجودة أو فاضية، اشتغل API فقط بدون static handler
  if (!publicDir.existsSync() || publicDir.listSync().isEmpty) {
    return serve(handler, ip, port);
  }

  final staticHandler = createStaticFileHandler(
    path: 'public',
    defaultDocument: 'index.html',
  );

  final cascade = Cascade()
      .add(staticHandler)
      .add(handler);

  return serve(cascade.handler, ip, port);
}
