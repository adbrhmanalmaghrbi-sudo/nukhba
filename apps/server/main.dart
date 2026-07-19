import 'dart:io';
import 'package:dart_frog/dart_frog.dart';
import 'package:path/path.dart' as p;

Future<HttpServer> run(Handler handler, InternetAddress ip, int port) async {
  final execDir = p.dirname(Platform.resolvedExecutable);
  final publicPath = p.join(execDir, 'public');
  print('Starting server, public: $publicPath');
  return serve(handler, ip, port);
}
