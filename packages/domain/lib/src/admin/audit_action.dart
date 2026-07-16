import 'package:shared/shared.dart';

/// The closed set of privileged admin actions recorded in the append-only audit
/// trail (Admin Panel decision OPEN-B #2: the audit log covers ALL admin
/// actions, not only the crown-jewel ledger/result ones the ADR names
/// explicitly).
///
/// Each value is the *kind* of a single `admin.audit_log` row. The set is
/// deliberately closed and validated (`tryParse`): an unknown token from
/// storage is a corrupt row, never silently coerced — mirroring how
/// `NotificationKind`/`ReactionKind`/`GroupRole` carry stable wire tokens.
/// Extending it (a new admin capability) is a forward-only enum + schema change.
///
/// The tokens map one-to-one onto the admin capabilities this phase delivers:
///
///   * [userSuspended] / [userReinstated] — the reversible user sanction
///     (decision OPEN-A #1); the ONLY genuinely-new domain capability, since
///     `UserStatus.suspended` had a hook but no transition use-case.
///   * [participantLedgerViewed] — the narrow cross-user read-for-support
///     (decision OPEN-A #3): a single participant's ledger, by explicit id,
///     itself audited (the support read gets NO silent exemption).
///   * [fixtureResultRecorded] / [roundScored] / [roundPostedToLedger] —
///     the crown-jewel competition/scoring/ledger actions that REUSE the
///     already-ratified admin-scoped use-cases (decision #1); logging them here
///     gives one consistent trail (Security ADR §2.4).
///   * [competitionCreated] / [seasonStarted] / [roundOpened] / [roundLocked] /
///     [fixtureLinkedToRound] — the competition-authoring admin commands, also
///     reused (decision #1) and logged for one consistent trail.
enum AuditAction {
  /// An admin suspended a user (reversible sanction; decision OPEN-A #1).
  userSuspended,

  /// An admin reinstated (un-suspended) a user.
  userReinstated,

  /// An admin viewed a single participant's ledger for support (decision
  /// OPEN-A #3 — narrow, read-only, itself audited).
  participantLedgerViewed,

  /// An admin recorded/corrected a fixture's actual result (reused
  /// `RecordFixtureResult`).
  fixtureResultRecorded,

  /// An admin scored a locked round (reused `ScoreRound`).
  roundScored,

  /// An admin posted a scored round to the append-only ledger (reused
  /// `PostRoundToLedger`).
  roundPostedToLedger,

  /// An admin created a competition (reused `CreateCompetition`).
  competitionCreated,

  /// An admin started a season (reused `StartSeason`).
  seasonStarted,

  /// An admin opened a round (reused `OpenRound`).
  roundOpened,

  /// An admin locked a round (reused `LockRound`).
  roundLocked,

  /// An admin linked a fixture to a round (reused `LinkFixtureToRound`).
  fixtureLinkedToRound;

  /// The stable wire/storage token for this action (snake_case, mirroring the
  /// migration's `admin.audit_action` enum values).
  String get wireValue => switch (this) {
    AuditAction.userSuspended => 'user_suspended',
    AuditAction.userReinstated => 'user_reinstated',
    AuditAction.participantLedgerViewed => 'participant_ledger_viewed',
    AuditAction.fixtureResultRecorded => 'fixture_result_recorded',
    AuditAction.roundScored => 'round_scored',
    AuditAction.roundPostedToLedger => 'round_posted_to_ledger',
    AuditAction.competitionCreated => 'competition_created',
    AuditAction.seasonStarted => 'season_started',
    AuditAction.roundOpened => 'round_opened',
    AuditAction.roundLocked => 'round_locked',
    AuditAction.fixtureLinkedToRound => 'fixture_linked_to_round',
  };

  /// Parses an [AuditAction] from an untrusted [raw] token, returning a
  /// validation [AppError] when it is absent or outside the closed set. Total,
  /// so a corrupt stored row surfaces as a typed failure rather than throwing.
  static Result<AuditAction> tryParse(String? raw) {
    for (final value in AuditAction.values) {
      if (value.wireValue == raw) {
        return Result.ok(value);
      }
    }
    return Result.err(
      AppError.validation(
        'admin.audit_action_unknown',
        'Unknown admin audit action: ${raw ?? '<null>'}',
      ),
    );
  }
}
