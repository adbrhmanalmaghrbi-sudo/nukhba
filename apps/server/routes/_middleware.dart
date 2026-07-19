import 'package:dart_frog/dart_frog.dart';
import 'package:server/composition/composition_root.dart';

Handler middleware(Handler handler) {
  return (context) async {
    // Serve static files without touching the database
    final path = context.request.uri.path;
    if (path == '/' || path.isEmpty) {
      return handler(context);
    }
    return handler
        .use(requestLogger())
        .use(_securityHeaders())
        .use(
          provider<Future<CompositionRoot>>(
            (_) => CompositionRoot.instance(),
          ),
        )(context);
  };
}

Middleware _securityHeaders() {
  return (handler) {
    return (context) async {
      final response = await handler(context);
      return response.copyWith(
        headers: {
          ...response.headers,
          'X-Content-Type-Options': 'nosniff',
          'X-Frame-Options': 'DENY',
          'Referrer-Policy': 'no-referrer',
        },
      );
    };
  };
}
