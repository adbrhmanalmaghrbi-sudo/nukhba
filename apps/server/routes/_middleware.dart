import 'package:dart_frog/dart_frog.dart';
import 'package:server/composition/composition_root.dart';

Handler middleware(Handler handler) {
  return (context) async {
    final path = context.request.uri.path;
    if (path == '/' || path == '') {
      return handler(context);
    }
    try {
      return await handler
          .use(requestLogger())
          .use(_securityHeaders())
          .use(provider<Future<CompositionRoot>>(
            (_) => CompositionRoot.instance(),
          ))(context);
    } catch (e) {
      return Response(statusCode: 503, body: 'Service unavailable: $e');
    }
  };
}

Middleware _securityHeaders() {
  return (handler) {
    return (context) async {
      final response = await handler(context);
      return response.copyWith(headers: {
        ...response.headers,
        'X-Content-Type-Options': 'nosniff',
        'X-Frame-Options': 'DENY',
        'Referrer-Policy': 'no-referrer',
      });
    };
  };
}
