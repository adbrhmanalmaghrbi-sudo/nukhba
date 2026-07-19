import 'dart:io';
import 'package:dart_frog/dart_frog.dart';
import 'package:path/path.dart' as p;

Future<Response> onRequest(RequestContext context) async {
  final execDir = p.dirname(Platform.resolvedExecutable);
  final publicDir = Directory(p.join(execDir, 'public'));

  final request = context.request;
  final urlPath = request.uri.path;

  // Determine which file to serve
  var filePath = urlPath == '/' ? 'index.html' : urlPath.replaceFirst('/', '');
  var file = File(p.join(publicDir.path, filePath));

  // SPA fallback
  if (!await file.exists()) {
    file = File(p.join(publicDir.path, 'index.html'));
  }

  if (!await file.exists()) {
    return Response(statusCode: 404, body: 'Not found');
  }

  final bytes = await file.readAsBytes();
  final ext = p.extension(file.path).toLowerCase();
  final contentType = _contentType(ext);

  return Response.bytes(
    body: bytes,
    headers: {'content-type': contentType},
  );
}

String _contentType(String ext) {
  switch (ext) {
    case '.html': return 'text/html; charset=utf-8';
    case '.js':   return 'application/javascript';
    case '.css':  return 'text/css';
    case '.png':  return 'image/png';
    case '.jpg':
    case '.jpeg': return 'image/jpeg';
    case '.ico':  return 'image/x-icon';
    case '.json': return 'application/json';
    case '.wasm': return 'application/wasm';
    default:      return 'application/octet-stream';
  }
}
