import 'package:dart_frog/dart_frog.dart';
import 'package:server/composition/composition_root.dart';

/// Root middleware: provides the composition root to every route and applies
/// baseline security headers.
///
/// Authentication is deliberately NOT enforced here. Making the whole tree
/// require a token would break the public `/health` probe (Roadmap ADR:
/// `/health` stays public). Instead, `bearerAuth` is scoped to the protected
/// subtrees that opt in via their own `_middleware.dart` (see
/// `routes/me/_middleware.dart`). The composition root — and therefore the
/// `AuthenticateRequest` use-case those subtrees rely on — is provided here so
/// it is available everywhere.
Handler middleware(Handler handler) {
  return handler
      .use(requestLogger())
      .use(_securityHeaders())
      .use(
        provider<Future<CompositionRoot>>((_) => CompositionRoot.instance()),
      );
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
