/// The infrastructure layer: concrete adapters implementing application ports.
///
/// Depends inward on application/domain/shared and outward on drivers
/// (postgres). Nothing depends on this package except the composition root
/// (Application ADR, Section 8).
library;

export 'src/admin/postgres_audit_log_repository.dart';
export 'src/admin/postgres_user_admin_repository.dart';
export 'src/common/system_clock.dart';
export 'src/common/uuid_id_generator.dart';
export 'src/common/uuid_invite_code_generator.dart';
export 'src/competition/configured_ruleset_provider.dart';
export 'src/competition/postgres_competition_repository.dart';
export 'src/db/postgres_config.dart';
export 'src/db/postgres_connection.dart';
export 'src/group/postgres_group_repository.dart';
export 'src/identity/auth_config.dart';
export 'src/identity/jwks_client.dart';
export 'src/identity/postgres_user_directory.dart';
export 'src/identity/supabase_jwt_verifier.dart';
export 'src/leaderboard/postgres_leaderboard_repository.dart';
export 'src/ledger/postgres_ledger_repository.dart';
export 'src/ledger/postgres_participant_reader.dart';
export 'src/notification/postgres_notification_repository.dart';
export 'src/platform/postgres_health_repository.dart';
export 'src/prediction/postgres_prediction_repository.dart';
export 'src/scoring/postgres_fixture_result_repository.dart';
export 'src/scoring/postgres_score_repository.dart';
export 'src/social/postgres_activity_feed_reader.dart';
export 'src/social/postgres_reaction_repository.dart';
