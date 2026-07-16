import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:server/http/error_envelope.dart';
import 'package:server/http/leaderboard_dto_mapper.dart';
import 'package:shared/shared.dart';

/// GET /seasons/{id}/leaderboard — read a season's ranked standings (API ADR §2:
/// a query; a leaderboard is a read-side projection over the append-only
/// ledger — Axiom 5, never a points write, so there is no command here).
///
/// The visibility gate lives entirely inside `GetSeasonLeaderboard`: the
/// standings are visible only to a **member of the season** (a caller who has
/// joined it, any status — a withdrawn member keeps their competitive record and
/// may still see the board they were part of), mirroring the predictions/scores
/// season-membership gate. A non-member is refused `401`
/// `leaderboard.not_a_participant` (so the response is not a season-existence
/// oracle beyond membership — Security ADR §2). There is NO admin gate — this is
/// a read, not a points write (Axiom 2 governs writes). This route only wires the
/// verified principal and the season id and shapes the result; it makes no
/// authorization decision of its own.
///
/// The `/seasons` subtree is already behind `bearerAuth`
/// (`routes/seasons/_middleware.dart`), which provides the [AuthenticatedUser];
/// an unauthenticated request never reaches this handler. Returns the
/// [SeasonLeaderboardDto] (`200`); an empty `entries` array means the season has
/// no participants (a legitimate empty board, distinct from the membership
/// refusal). `405` on any non-GET method.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final root = await context.read<Future<CompositionRoot>>();
  final principal = context.read<AuthenticatedUser>();

  final result = await root.getSeasonLeaderboard(
    principal: principal,
    seasonId: id,
  );

  return switch (result) {
    Ok<SeasonLeaderboard>(:final value) => Response.json(
      body: seasonLeaderboardToJson(value),
    ),
    Err<SeasonLeaderboard>(:final error) => errorResponse(error),
  };
}
