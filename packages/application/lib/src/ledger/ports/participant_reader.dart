import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// A narrow read port that resolves a [Participant] by its own id
/// (Application ADR §9: use-cases depend on repository interfaces).
///
/// The Ledger read use-case is keyed by **participant id** (the wire surface is
/// `GET /participants/{id}/balance` and `.../entries`, API ADR §4), but the
/// caller is authenticated as a *user*. To gate the read to a self-read (a
/// caller sees only their own ledger — Security ADR §2), the use-case must map a
/// participant id back to the owning user id. The frozen
/// `CompetitionRepository` only offers `findParticipant(seasonId, userId)` — it
/// has no by-id lookup — and that port must not change without approval
/// (Roadmap ADR §rules). Rather than widen a ratified surface, the Ledger slice
/// introduces this **new, single-method** port; Infrastructure implements it by
/// reading the same `competition.participants` row the competition adapter owns.
///
/// This is a new internal port inside the existing `application` package (no new
/// package), so `tooling/import_lint` is unaffected.
///
/// General contract (Application ADR §2):
/// * MUST NOT throw — every outcome is a typed [Result].
/// * MUST map infrastructure failures to [ErrorKind.transient].
abstract interface class ParticipantReader {
  /// Returns the [Participant] identified by [id], or `Ok(null)` when no such
  /// participant exists. The Ledger read use-case compares the returned
  /// participant's `userId` to the caller's principal to enforce self-read;
  /// a `null` result is reported to the caller as "not found" (never leaking
  /// whether the id belongs to someone else).
  Future<Result<Participant?>> findParticipantById(ParticipantId id);
}
