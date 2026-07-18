import 'dart:io';

import 'package:dart_frog/dart_frog.dart';

Future<HttpServer> run(Handler handler, InternetAddress ip, int port) {
  final staticHandler = createStaticFileHandler(
    path: 'public',
    useHeaderBytesForContentType: true,
  );

  final cascade = Cascade()
      .add(staticHandler)
      .add(handler);

  return serve(cascade.handler, ip, port);
}
