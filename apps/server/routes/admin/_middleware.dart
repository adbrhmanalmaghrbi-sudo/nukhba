import 'package:dart_frog/dart_frog.dart';
import 'package:server/http/bearer_auth.dart';

/// Guards the whole `/admin` subtree with bearer authentication (Security ADR
/// §2), mirroring `/participants` and `/notifications`.
///
/// Authentication (a verified principal) is enforced here at the subtree edge;
/// **authorization** (the caller is a `PlatformRole.admin`) is enforced INSIDE
/// each admin use-case (`SuspendUser`/`ReinstateUser`/`ListAuditLog`/
/// `ViewParticipantLedger` all call `Authorization.requireRole(principal,
/// PlatformRole.admin)` first — Admin Panel decision §2 #2, Security ADR §2.3).
/// So this middleware only establishes WHO the caller is; whether they are
/// allowed is the use-case's call, and a non-admin is refused identically as a
/// `401 auth.insufficient_role` with no capability oracle — never split into a
/// separate route-layer gate. There is deliberately NO separate admin auth path
/// (decision §2 #2 — admin is the existing `PlatformRole.admin` on the shipped
/// identity/JWT model), so this reuses `bearerAuth` unchanged.
Handler middleware(Handler handler) {
  return handler.use(bearerAuth());
}
