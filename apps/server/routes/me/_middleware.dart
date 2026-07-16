import 'package:dart_frog/dart_frog.dart';
import 'package:server/http/bearer_auth.dart';

/// Applies bearer authentication to everything under `/me` (Security ADR,
/// Section 2). Auth is scoped *here*, not in the root middleware, so public
/// routes such as `/health` stay open while this subtree is gated: an
/// unauthenticated request never reaches `routes/me/index.dart`.
Handler middleware(Handler handler) {
  return handler.use(bearerAuth());
}
