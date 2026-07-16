import 'package:domain/src/competition/competition_id.dart';
import 'package:shared/shared.dart';

/// The identity of a [Participant] aggregate root (Database ADR, Section 1:
/// Participant is deliberately its own aggregate, separate from Competition, so
/// that high-volume prediction writes never lock the Competition aggregate).
///
/// A value object (Coding Standards ADR, Section 2), canonically a UUID matching
/// the `competition.participants` primary key. A later-phase `Prediction`
/// references exactly one [ParticipantId]; a `PointEntry` references it too.
final class ParticipantId extends EntityId {
  /// Creates a [ParticipantId] from its canonical UUID string.
  const ParticipantId(super.value);

  /// Parses a [ParticipantId] from an untrusted [raw] string, returning a
  /// validation [AppError] when it is absent or not a canonical UUID.
  static Result<ParticipantId> tryParse(String? raw) {
    if (raw == null || raw.isEmpty) {
      return const Result.err(
        AppError.validation(
          'competition.participant_id_empty',
          'Participant id is required',
        ),
      );
    }
    if (!uuidPattern.hasMatch(raw)) {
      return const Result.err(
        AppError.validation(
          'competition.participant_id_malformed',
          'Participant id must be a UUID',
        ),
      );
    }
    return Result.ok(ParticipantId(raw));
  }
}
