import 'dart:io';

import 'package:application/application.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:server/http/error_envelope.dart';
import 'package:server/http/group_dto_mapper.dart';
import 'package:shared/shared.dart';

/// GET /groups/{id}/seasons/{seasonId}/leaderboard — read a **group's** ranked
/// standings for a season (API ADR §2: a query, not a command).
///
/// The board is the ratified `leaderboard.season_standings` projection over the
/// append-only ledger, filtered to the group's membership (Groups decision #4:
/// NO new points source, NO new ranking logic — only the participant-set filter
/// is new). Totals therefore always agree with what each member reads at
/// `GET /participants/{id}/balance` and on the season board (Axiom 5, a single
/// protected truth for points); ranks come verbatim from the pure domain
/// `SeasonLeaderboard.rank` ("1224" standard-competition ranks, deterministic
/// tie-break). Nothing here is client-writable (Axioms 2/5).
///
/// **Member-only visibility gate (decision #3, mirror of the season-membership
/// gate):** only a member of the group may read its board. The gate lives
/// entirely inside `GetGroupLeaderboard`; a non-member is refused `401`
/// `group.not_a_member` identically whether or not the group exists (no
/// existence oracle). There is NO admin gate — a group leaderboard is a read,
/// not a points write (Axiom 2 governs writes). This route makes no
/// authorization decision of its own; it only wires the verified principal, the
/// path group id + season id, and shapes the result.
///
/// The `/groups` subtree is already behind `bearerAuth`
/// (`routes/groups/_middleware.dart`), which provides the [AuthenticatedUser];
/// an unauthenticated request never reaches this handler. Returns the
/// [GroupLeaderboardDto] (`200`); an empty `entries` array is a legitimate empty
/// board (a group whose members are not season participants, or have never been
/// credited), distinct from the membership refusal. `405` on any non-GET method.
Future<Response> onRequest(
  RequestContext context,
  String id,
  String seasonId,
) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final root = await context.read<Future<CompositionRoot>>();
  final principal = context.read<AuthenticatedUser>();

  final result = await root.getGroupLeaderboard(
    principal: principal,
    groupId: id,
    seasonId: seasonId,
  );

  return switch (result) {
    Ok<GroupLeaderboard>(:final value) => Response.json(
      body: groupLeaderboardJson(value),
    ),
    Err<GroupLeaderboard>(:final error) => errorResponse(error),
  };
}
