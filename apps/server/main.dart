import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:path/path.dart' as p;

Future<HttpServer> run(Handler handler, InternetAddress ip, int port) {
  // احسب مسار public نسبةً لموقع الملف التنفيذي، مش لمجلد العمل الحالي
  final exeDir = p.dirname(Platform.resolvedExecutable);
  final publicPath = p.join(exeDir, 'public');
  final publicDir = Directory(publicPath);

  print('CWD: ${Directory.current.path}');
  print('Executable dir: $exeDir');
  print('Looking for public at: $publicPath');
  print('public exists: ${publicDir.existsSync()}');

  if (!publicDir.existsSync() || publicDir.listSync().isEmpty) {
    print('WARNING: public not found — running API-only mode');
    return serve(handler, ip, port);
  }

  final staticHandler = createStaticFileHandler(
    path: publicPath,
    defaultDocument: 'index.html',
  );

  final cascade = Cascade()
      .add(staticHandler)
      .add(handler);

  return serve(cascade.handler, ip, port);
}
