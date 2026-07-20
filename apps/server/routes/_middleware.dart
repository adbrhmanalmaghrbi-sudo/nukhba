import 'dart:io';

import 'package:dart_frog/dart_frog.dart';

/// Origins allowed to call this API from a browser.
///
/// The frontend (Flutter Web) is hosted on GitHub Pages, a different origin
/// from this API (hosted on Google Cloud Run), so CORS headers are required for browser
/// requests to succeed at all (server-to-server / non-browser clients are
/// unaffected either way).
///
/// Configurable via `NUKHBA_CORS_ALLOWED_ORIGINS` (comma-separated) so the
/// allow-list can be tightened or extended per environment without a code
/// change. Falls back to the known GitHub Pages origin + localhost (for
/// `flutter run -d chrome` during local development).
List<String> _allowedOrigins() {
  final raw = Platform.environment['NUKHBA_CORS_ALLOWED_ORIGINS'];
  if (raw == null || raw.trim().isEmpty) {
    return const [
      'https://adbrhmanalmaghrbi-sudo.github.io',
      'http://localhost:*',
    ];
  }
  return raw
      .split(',')
      .map((o) => o.trim())
      .where((o) => o.isNotEmpty)
      .toList();
}

bool _originAllowed(String? origin, List<String> allowed) {
  if (origin == null) return false;
  for (final pattern in allowed) {
    if (pattern.endsWith(':*')) {
      final prefix = pattern.substring(
        0,
        pattern.length - 1,
      ); // keep trailing ':'
      if (origin.startsWith(prefix)) return true;
    } else if (pattern == origin) {
      return true;
    }
  }
  return false;
}

Handler middleware(Handler handler) {
  final allowed = _allowedOrigins();

  return (context) async {
    final origin = context.request.headers['origin'];
    final corsHeaders = <String, Object>{
      if (_originAllowed(origin, allowed))
        'Access-Control-Allow-Origin': origin!,
      'Access-Control-Allow-Methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS',
      'Access-Control-Allow-Headers': 'Authorization, Content-Type',
      'Access-Control-Max-Age': '86400',
      'Vary': 'Origin',
    };

    // Preflight requests never reach downstream handlers/auth middleware.
    if (context.request.method == HttpMethod.options) {
      return Response(statusCode: 204, headers: corsHeaders);
    }

    final response = await handler(context);
    return response.copyWith(headers: {...response.headers, ...corsHeaders});
  };
}
