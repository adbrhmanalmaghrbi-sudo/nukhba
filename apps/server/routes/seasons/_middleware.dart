import 'package:dart_frog/dart_frog.dart';
import 'package:server/http/bearer_auth.dart';

/// Guards the whole `/seasons` command subtree with bearer authentication
/// (Security ADR §2). Opening a round is admin-only (enforced in the use-case);
/// joining is open to any authenticated user (enforced in the use-case).
Handler middleware(Handler handler) {
  return handler.use(bearerAuth());
}
