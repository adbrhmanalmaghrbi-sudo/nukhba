import 'package:dart_frog/dart_frog.dart';
import 'package:server/http/bearer_auth.dart';

/// Guards the whole `/groups` subtree with bearer authentication (Security ADR
/// §2), mirroring `/participants` and `/seasons`. A group is a private,
/// invite-only community first-class from the architectural root (Axiom 2), so
/// every group surface requires a verified principal.
///
/// The finer authorization lives inside each use-case, not here:
///   * membership visibility (`group.not_a_member`, no existence oracle —
///     Groups decision #3) for the reads;
///   * per-group owner authority (`group.not_owner`) for rename / invite
///     regeneration (decision #2) — the per-group `GroupRole`, never the
///     platform role.
/// This middleware only proves the caller is authenticated; it makes no
/// group-scoped authorization decision.
Handler middleware(Handler handler) {
  return handler.use(bearerAuth());
}
