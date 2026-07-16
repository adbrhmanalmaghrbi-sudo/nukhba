import 'package:dart_frog/dart_frog.dart';
import 'package:server/http/bearer_auth.dart';

/// Guards the whole `/rounds` command subtree with bearer authentication
/// (Security ADR §2). Locking a round and linking a fixture are admin-only,
/// enforced as the second layer inside each use-case.
Handler middleware(Handler handler) {
  return handler.use(bearerAuth());
}
