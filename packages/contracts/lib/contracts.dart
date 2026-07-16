/// Versioned API contracts (DTOs) shared between the Flutter client and the
/// backend (Application ADR, Section 3; API ADR, Section 4).
///
/// This package depends on nothing so both sides compile against identical
/// shapes. Every DTO carries a schema version to support gradual rollout and
/// archived-event replay (Database ADR, Section 12).
library;

export 'src/admin_dto.dart';
export 'src/competition_dto.dart';
export 'src/error_dto.dart';
export 'src/group_dto.dart';
export 'src/health_dto.dart';
export 'src/leaderboard_dto.dart';
export 'src/ledger_dto.dart';
export 'src/me_dto.dart';
export 'src/notification_dto.dart';
export 'src/prediction_dto.dart';
export 'src/scoring_dto.dart';
export 'src/social_dto.dart';
