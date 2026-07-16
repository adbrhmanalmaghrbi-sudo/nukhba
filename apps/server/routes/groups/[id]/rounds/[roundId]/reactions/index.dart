import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:server/http/error_envelope.dart';
import 'package:server/http/json_body.dart';
import 'package:server/http/social_dto_mapper.dart';
import 'package:shared/shared.dart';

/// `/groups/{id}/rounds/{roundId}/reactions` — a group member's emoji reaction
/// to a round-result (Social decision #1: bounded reactions, group-scoped,
/// round-targeted; the ONE new stored Tier-3 surface — decision #2).
///
/// Reactions live UNDER `/groups/{id}/...` so they inherit the `/groups`
/// `bearerAuth` subtree (`routes/groups/_middleware.dart`) and are group-scoped
/// by construction (decision #3). Every authorization decision (the member-only
/// `group.not_a_member` gate, no existence oracle) lives inside the use-case;
/// this route makes none. The author is bound from the verified token inside the
/// use-case, never a request body (Security ADR §2).
///
/// Methods:
///   * `PUT` — react or change (idempotent upsert on `(group, round, user)`).
///     Body: `{ "emoji": string }` (one of the closed wire tokens). → `200`
///     [ReactionDto].
///   * `DELETE` — remove the caller's own reaction (idempotent; removing an
///     absent one is a success). → `200` `{ "removed": bool }`.
///   * `GET` — list the round's reactions within the group (member-gated). →
///     `200` [RoundReactionsDto].
///   * anything else → `405`.
///
/// **Tier-3 degradation (decision #4):** any failure here is confined to the
/// Social use-case and returned as the uniform error envelope; it never blocks a
/// Tier-1 core operation.
Future<Response> onRequest(
  RequestContext context,
  String id,
  String roundId,
) async {
  final method = context.request.method;
  return switch (method) {
    HttpMethod.put => _react(context, id, roundId),
    HttpMethod.delete => _remove(context, id, roundId),
    HttpMethod.get => _list(context, id, roundId),
    _ => Response(statusCode: HttpStatus.methodNotAllowed),
  };
}

Future<Response> _react(
  RequestContext context,
  String id,
  String roundId,
) async {
  final root = await context.read<Future<CompositionRoot>>();
  final principal = context.read<AuthenticatedUser>();

  final bodyResult = await readJsonObject(context.request);
  if (bodyResult is Err<Map<String, Object?>>) {
    return errorResponse(bodyResult.error);
  }
  final body = (bodyResult as Ok<Map<String, Object?>>).value;

  final emoji = requireString(body, 'emoji');
  if (emoji is Err<String>) {
    return errorResponse(emoji.error);
  }

  final result = await root.reactToRound(
    principal: principal,
    groupId: id,
    roundId: roundId,
    emoji: (emoji as Ok<String>).value,
  );

  return switch (result) {
    Ok<Reaction>(:final value) => Response.json(
      body: reactionToDto(value).toJson(),
    ),
    Err<Reaction>(:final error) => errorResponse(error),
  };
}

Future<Response> _remove(
  RequestContext context,
  String id,
  String roundId,
) async {
  final root = await context.read<Future<CompositionRoot>>();
  final principal = context.read<AuthenticatedUser>();

  final result = await root.removeReaction(
    principal: principal,
    groupId: id,
    roundId: roundId,
  );

  return switch (result) {
    // The boolean is echoed so a client can tell an actual removal (true) from
    // a no-op (false); both are `200` (idempotent — decision #2).
    Ok<bool>(:final value) => Response.json(body: {'removed': value}),
    Err<bool>(:final error) => errorResponse(error),
  };
}

Future<Response> _list(
  RequestContext context,
  String id,
  String roundId,
) async {
  final root = await context.read<Future<CompositionRoot>>();
  final principal = context.read<AuthenticatedUser>();

  final result = await root.listRoundReactions(
    principal: principal,
    groupId: id,
    roundId: roundId,
  );

  return switch (result) {
    Ok<List<Reaction>>(:final value) => Response.json(
      body: roundReactionsJson(id, roundId, value),
    ),
    Err<List<Reaction>>(:final error) => errorResponse(error),
  };
}
