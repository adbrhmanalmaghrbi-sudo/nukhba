import 'dart:io';
import 'package:dart_frog/dart_frog.dart';
import 'package:path/path.dart' as p;

Future<Response> onRequest(RequestContext context) async {
  final execDir = p.dirname(Platform.resolvedExecutable);
  final file = File(p.join(execDir, 'public', 'index.html'));
  final exists = await file.exists();
  final size = exists ? await file.length() : 0;
  print('GET / → file: ${file.path}, exists: $exists, size: $size');
  if (!exists) {
    return Response(statusCode: 404, body: 'NOT FOUND: ${file.path}');
  }
  final bytes = await file.readAsBytes();
  return Response.bytes(
    body: bytes,
    headers: {'content-type': 'text/html; charset=utf-8'},
  );
}
