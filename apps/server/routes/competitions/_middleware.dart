import 'package:dart_frog/dart_frog.dart';
import 'package:server/http/bearer_auth.dart';

/// Guards the whole `/competitions` command subtree with bearer authentication
/// (Security ADR §2). Auth is scoped per-subtree, never globally, so `/health`
/// stays public. Per-command authorization (admin-only for create/season) is a
/// second layer enforced inside each use-case.
Handler middleware(Handler handler) {
  return handler.use(bearerAuth());
}
