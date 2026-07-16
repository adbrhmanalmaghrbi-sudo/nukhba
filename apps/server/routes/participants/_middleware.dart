import 'package:dart_frog/dart_frog.dart';
import 'package:server/http/bearer_auth.dart';

/// Guards the whole `/participants` read subtree with bearer authentication
/// (Security ADR §2). Reading a participant's ledger balance/entries is a
/// self-read: the use-case (`ReadParticipantLedger`) additionally enforces that
/// the verified caller OWNS the participant, reporting a foreign or unknown id
/// identically as not-found so the response is never an ownership oracle.
Handler middleware(Handler handler) {
  return handler.use(bearerAuth());
}
