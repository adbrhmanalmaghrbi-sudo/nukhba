import 'package:shared/shared.dart';

/// The lifecycle state of a [Participant] within a `CompetitionSeason`.
///
/// Kept minimal for the Competition phase (Database ADR, Section 3): a
/// participant is either actively competing or has withdrawn. Withdrawal never
/// deletes the row — the competitive record is an asset to protect (Axiom 5),
/// and ledger entries reference the participant (Database ADR, Section: "cannot
/// delete a participant that has ledger entries"). Later phases may extend the
/// transition policy, but the closed set is fixed here.
enum ParticipantStatus {
  /// Actively competing in the season: predictions count toward rankings.
  active,

  /// Voluntarily left the season. Historical predictions and points are
  /// preserved; the participant simply stops accruing new standing.
  withdrawn;

  /// The stable wire/storage token for this status.
  String get wireValue => switch (this) {
    ParticipantStatus.active => 'active',
    ParticipantStatus.withdrawn => 'withdrawn',
  };

  /// Whether a participant in this status is actively competing.
  bool get isActive => this == ParticipantStatus.active;

  /// Parses a [ParticipantStatus] from an untrusted [raw] token, returning a
  /// validation [AppError] when it is absent or unrecognized.
  static Result<ParticipantStatus> tryParse(String? raw) {
    for (final value in ParticipantStatus.values) {
      if (value.wireValue == raw) {
        return Result.ok(value);
      }
    }
    return Result.err(
      AppError.validation(
        'competition.participant_status_unknown',
        'Unknown participant status: ${raw ?? '<null>'}',
      ),
    );
  }
}
