import 'dart:io';

import 'package:application/application.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:server/http/error_envelope.dart';
import 'package:server/http/social_dto_mapper.dart';
import 'package:shared/shared.dart';

/// `GET /groups/{id}/feed` — read a group's activity feed (API ADR §2: a query;
/// the feed is a pure read projection over already-ratified data — Social
/// decision #2, NO table, never a source of truth).
///
/// The feed lives UNDER `/groups/{id}/...` so it inherits the `/groups`
/// `bearerAuth` subtree (`routes/groups/_middleware.dart`) and is group-scoped by
/// construction (decision #3). The member-only visibility gate
/// (`group.not_a_member`, no existence oracle) lives entirely inside
/// `GetGroupActivityFeed`; this route makes no authorization decision.
///
/// An optional `?limit=` query parameter caps the number of events; the use-case
/// clamps an untrusted value to `[1, GetGroupActivityFeed.maxLimit]`, falling
/// back to the default for a null/non-positive/non-integer value, so a Tier-3
/// read never triggers an unbounded scan (decision #4). A non-integer `limit` is
/// treated as absent (the clamp handles it) rather than a `400`, since the
/// parameter is an optional hint, not a required field.
///
/// Returns a [GroupActivityFeedDto] (`200`); an empty `events` array is a
/// legitimate empty feed (a fresh group), distinct from the membership refusal.
/// `405` on any non-GET method.
///
/// **Tier-3 degradation (decision #4):** a feed-assembly failure is returned as
/// the uniform error envelope; it never blocks a Tier-1 core operation.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final root = await context.read<Future<CompositionRoot>>();
  final principal = context.read<AuthenticatedUser>();

  // Optional hint; a missing/non-integer value is passed as null so the
  // use-case applies its default. int.tryParse returns null for anything that
  // is not a plain integer, which is exactly the "treat as absent" behaviour.
  final rawLimit = context.request.uri.queryParameters['limit'];
  final limit = rawLimit == null ? null : int.tryParse(rawLimit);

  final result = await root.getGroupActivityFeed(
    principal: principal,
    groupId: id,
    limit: limit,
  );

  return switch (result) {
    Ok<List<ActivityEvent>>(:final value) => Response.json(
      body: groupActivityFeedJson(id, value),
    ),
    Err<List<ActivityEvent>>(:final error) => errorResponse(error),
  };
}
