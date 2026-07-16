import 'package:domain/src/competition/competition_id.dart';
import 'package:shared/shared.dart';

/// The identity of a [PointEntry], the append-only unit of the Ledger stream
/// (Database ADR, Section 3: Ledger = "append-only `PointEntry` stream; balance
/// is a projection").
///
/// A value object (Coding Standards ADR, Section 2), canonically a UUID matching
/// the `ledger.point_entries` primary key. Every entry has a stable identity of
/// its own — distinct from the `(participant, round, kind)` natural dedupe key —
/// so an entry can be referenced, ordered, and audited individually even though
/// the stream is never mutated in place (Axiom 5).
final class PointEntryId extends EntityId {
  /// Creates a [PointEntryId] from its canonical UUID string.
  const PointEntryId(super.value);

  /// Parses a [PointEntryId] from an untrusted [raw] string, returning a
  /// validation [AppError] when it is absent or not a canonical UUID.
  static Result<PointEntryId> tryParse(String? raw) {
    if (raw == null || raw.isEmpty) {
      return const Result.err(
        AppError.validation(
          'ledger.point_entry_id_empty',
          'Point entry id is required',
        ),
      );
    }
    if (!uuidPattern.hasMatch(raw)) {
      return const Result.err(
        AppError.validation(
          'ledger.point_entry_id_malformed',
          'Point entry id must be a UUID',
        ),
      );
    }
    return Result.ok(PointEntryId(raw));
  }
}
