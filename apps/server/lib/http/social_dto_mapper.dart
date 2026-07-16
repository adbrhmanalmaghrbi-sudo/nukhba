import 'package:application/application.dart';
import 'package:contracts/contracts.dart';
import 'package:domain/domain.dart';

/// Projects the Social (Tier-3) domain/application read values onto their
/// versioned wire shapes (API ADR §4), in one place, so every social
/// read/command response shapes an entity identically.
///
/// Social is a Tier-3 peripheral projection (Database ADR §3), group-scoped
/// (decision #3, no open graph) and NEVER a second points source (Axiom 5):
/// none of these shapes carry a points-write field or an open-graph edge. The
/// reaction [ReactionEmoji] and the [ActivityEventType] cross the wire as their
/// stable `wireValue` token (the glyph/label is a client presentation concern),
/// mirroring how `GroupMembershipDto.role` carries a token, not presentation.

/// Projects one domain [Reaction] onto the wire [ReactionDto].
///
/// The chosen emoji crosses the wire as its stable [ReactionEmoji.wireValue]
/// token (one of the closed set), never a glyph or a Dart enum name. Carries no
/// points field (Axiom 5) and no open-graph edge (ADR-001).
ReactionDto reactionToDto(Reaction reaction) {
  return ReactionDto(
    id: reaction.id.value,
    groupId: reaction.groupId.value,
    roundId: reaction.roundId.value,
    userId: reaction.userId.value,
    emoji: reaction.emoji.wireValue,
    // Always UTC (the domain Reaction.create/changeEmoji enforce isUtc);
    // ISO-8601.
    reactedAt: reaction.reactedAt.toUtc().toIso8601String(),
  );
}

/// Shapes the response of `GET /groups/{id}/rounds/{roundId}/reactions` — the
/// round's reactions within the group, in the server-defined order (reactedAt
/// ascending). An empty [reactions] list is a legitimate result (no member has
/// reacted yet), never an error.
Map<String, Object?> roundReactionsJson(
  String groupId,
  String roundId,
  List<Reaction> reactions,
) {
  return RoundReactionsDto(
    groupId: groupId,
    roundId: roundId,
    reactions: [for (final r in reactions) reactionToDto(r)],
  ).toJson();
}

/// Projects one application read value [ActivityEvent] onto the wire
/// [ActivityEventDto].
///
/// The [ActivityEventType] crosses the wire as its stable `wireValue` token
/// (`round_scored`/`member_joined`/`rank_shift`). The type-specific fields are
/// passed through as-is (the DTO omits the null ones from JSON), so the payload
/// stays minimal per event type. Carries no points-write field and no
/// open-graph edge.
ActivityEventDto activityEventToDto(ActivityEvent event) {
  return ActivityEventDto(
    type: event.type.wireValue,
    groupId: event.groupId.value,
    // Always UTC (the reader normalizes to UTC); ISO-8601.
    occurredAt: event.occurredAt.toUtc().toIso8601String(),
    roundId: event.roundId?.value,
    userId: event.userId?.value,
    oldRank: event.oldRank,
    newRank: event.newRank,
  );
}

/// Shapes the response of `GET /groups/{id}/feed` — the group's activity feed in
/// the server-defined order (occurredAt descending — newest first). An empty
/// [events] list is a legitimate result (a fresh group), never an error.
Map<String, Object?> groupActivityFeedJson(
  String groupId,
  List<ActivityEvent> events,
) {
  return GroupActivityFeedDto(
    groupId: groupId,
    events: [for (final e in events) activityEventToDto(e)],
  ).toJson();
}
