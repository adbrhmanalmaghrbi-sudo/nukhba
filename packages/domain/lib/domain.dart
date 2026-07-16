/// The pure domain layer.
///
/// Depends ONLY on `shared`. It must never import a framework, an HTTP
/// library, a database driver, or Flutter (Application ADR, Section 5;
/// Coding Standards ADR, Section 1). This constraint is enforced by the
/// import-lint tool in CI.
library;

export 'src/admin/audit_action.dart';
export 'src/admin/audit_entry.dart';
export 'src/admin/audit_entry_id.dart';
export 'src/competition/competition.dart';
export 'src/competition/competition_id.dart';
export 'src/competition/competition_season.dart';
export 'src/competition/competition_visibility.dart';
export 'src/competition/fixture_ref.dart';
export 'src/competition/format_type.dart';
export 'src/competition/participant.dart';
export 'src/competition/participant_id.dart';
export 'src/competition/participant_status.dart';
export 'src/competition/round.dart';
export 'src/competition/round_fixture.dart';
export 'src/competition/round_id.dart';
export 'src/competition/round_status.dart';
export 'src/competition/ruleset_snapshot.dart';
export 'src/competition/season_id.dart';
export 'src/group/group.dart';
export 'src/group/group_id.dart';
export 'src/group/group_membership.dart';
export 'src/group/group_membership_id.dart';
export 'src/group/group_role.dart';
export 'src/group/invite_code.dart';
export 'src/identity/authenticated_user.dart';
export 'src/identity/platform_role.dart';
export 'src/identity/user.dart';
export 'src/identity/user_id.dart';
export 'src/leaderboard/leaderboard_entry.dart';
export 'src/leaderboard/season_leaderboard.dart';
export 'src/ledger/entry_kind.dart';
export 'src/ledger/ledger_balance.dart';
export 'src/ledger/point_entry.dart';
export 'src/ledger/point_entry_id.dart';
export 'src/notification/notification.dart';
export 'src/notification/notification_id.dart';
export 'src/notification/notification_kind.dart';
export 'src/notification/notification_subject.dart';
export 'src/platform/health.dart';
export 'src/prediction/fixture_score_prediction.dart';
export 'src/prediction/prediction.dart';
export 'src/prediction/prediction_id.dart';
export 'src/scoring/fixture_result.dart';
export 'src/scoring/fixture_score_result.dart';
export 'src/scoring/round_score.dart';
export 'src/scoring/scoring.dart';
export 'src/scoring/scoring_ruleset.dart';
export 'src/social/reaction.dart';
export 'src/social/reaction_emoji.dart';
export 'src/social/reaction_id.dart';
