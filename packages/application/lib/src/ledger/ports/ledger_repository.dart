import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Persistence port for the append-only **Ledger** — the protected competitive
/// record (Axiom 5; Database ADR: "append-only `PointEntry` stream; balance is
/// a projection"; Application ADR §9: use-cases depend on repository
/// interfaces, Infrastructure implements them).
///
/// Backed by `PostgresLedgerRepository` over the new `ledger.point_entries`
/// table (migration `0005_ledger.sql`). The interface speaks in the domain
/// [PointEntry] aggregate, [LedgerBalance] projection, and typed ids — never in
/// rows or SQL — so use-cases stay pure and testable against an in-memory fake.
///
/// The ledger is **append-only and immutable** (Axiom 5): this port offers
/// [appendEntries] but deliberately **no** update or delete method. A
/// correction is a new compensating entry, never an in-place edit. The
/// migration additionally revokes UPDATE/DELETE and installs an immutability
/// trigger as the backstop (Axiom 6).
///
/// General contract for every method (Application ADR §2):
/// * MUST NOT throw — every outcome is a typed [Result].
/// * MUST map infrastructure failures to [ErrorKind.transient].
/// * MUST map a storage-only integrity conflict to [ErrorKind.invariant].
abstract interface class LedgerRepository {
  /// Appends [entries] to the ledger **atomically** (all-or-nothing) and
  /// **idempotently** on the natural dedupe key `(participant_id, round_id,
  /// entry_kind)` for a kind that is deduped per round (a `round_score`
  /// credit): re-appending an already-present `(participant, round,
  /// round_score)` row is skipped, never duplicated, so posting the same scored
  /// round twice can never double-credit (Axiom 4).
  ///
  /// Returns the subset of [entries] that were **actually appended** by this
  /// call — an entry already present under the dedupe key is omitted from the
  /// result (the caller reports it as "nothing new posted"). The whole batch is
  /// one transaction: a mid-write failure leaves the ledger untouched (Axiom 5,
  /// the competitive record is never half-written).
  ///
  /// Implementations MUST NOT mutate or delete any existing entry; the only
  /// effect is appending new rows (or skipping a duplicate).
  Future<Result<List<PointEntry>>> appendEntries(List<PointEntry> entries);

  /// Lists every [PointEntry] for [participantId], in the ledger's stream order
  /// (occurred-at ascending, then entry id for a stable tie-break). An empty
  /// list means the participant has no ledger movements yet.
  Future<Result<List<PointEntry>>> listEntries(ParticipantId participantId);

  /// Returns the projected [LedgerBalance] for [participantId] — the signed sum
  /// over their append-only stream (never a stored mutable total — Axiom 5).
  ///
  /// Implementations MAY compute this via a database projection/view for
  /// efficiency, but the returned value MUST equal the domain
  /// `LedgerBalance.project` over [listEntries]'s result (a participant with no
  /// entries projects a zero balance).
  Future<Result<LedgerBalance>> balanceFor(ParticipantId participantId);
}
