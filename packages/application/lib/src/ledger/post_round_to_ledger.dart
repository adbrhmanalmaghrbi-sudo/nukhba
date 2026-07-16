import 'package:application/src/common/clock.dart';
import 'package:application/src/common/id_generator.dart';
import 'package:application/src/competition/ports/competition_repository.dart';
import 'package:application/src/identity/authorization.dart';
import 'package:application/src/ledger/ports/ledger_repository.dart';
import 'package:application/src/scoring/ports/score_repository.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Command use-case: post a **scored** round to the append-only Ledger
/// (Application ADR §2: command intent `PostRoundToLedger`).
///
/// This is the Scoring → Ledger seam, realized as a **separate, explicit
/// admin/server-triggered command** rather than a domain event emitted by
/// `ScoreRound` (the architecture decision ratified in §2 before any code — it
/// keeps Scoring's public surface untouched and stays inside the event-driven
/// boundary, ADR 0002). It:
/// 1. authorizes the caller as an **admin** (Axiom 2: the client never posts
///    points — only the platform turns scores into the protected competitive
///    record), mirroring `ScoreRound`'s admin gate;
/// 2. loads the round via [CompetitionRepository.findRound] and gates on
///    [RoundStatus.scored] — a round may be posted to the ledger only once its
///    scores are final (`ledger.round_not_scored` otherwise). This is the
///    application's first line of defence; the migration's constraints/RLS are
///    the backstop (Axiom 6);
/// 3. reads the already-persisted [RoundScore]s via
///    [ScoreRepository.listByRound] (a *read* of Scoring's output — never a
///    mutation of Scoring's surface);
/// 4. builds exactly one [PointEntry] of kind [EntryKind.roundScore] per
///    participant, carrying that round's `RoundScore.totalPoints` as the signed
///    [PointEntry.amount] and the originating score's provenance in
///    [PointEntry.sourceRef];
/// 5. appends them **atomically and idempotently** via
///    [LedgerRepository.appendEntries] — the adapter dedupes on the ratified
///    `(participant_id, round_id, entry_kind)` key, so re-posting the same
///    scored round appends nothing new and never double-credits (Axiom 4).
///
/// **Idempotent** (Application ADR §2; Axiom 4): a replay of an already-posted
/// round is a no-op on the ledger — [LedgerRepository.appendEntries] returns the
/// subset actually appended (empty on replay), which this use-case returns
/// verbatim so the caller reports "nothing new posted" without a spurious
/// failure. Because the ledger is append-only (Axiom 5), the dedupe is a *skip*,
/// never an update/delete.
///
/// A round with no scored participants (scored, but nobody predicted) posts zero
/// entries — a legitimate empty result, not an error.
///
/// Never throws; returns a typed [Result] carrying the entries appended by this
/// post (empty on an idempotent replay or an empty round).
final class PostRoundToLedger {
  /// Creates the use-case over its collaborators.
  const PostRoundToLedger({
    required CompetitionRepository competitionRepository,
    required ScoreRepository scoreRepository,
    required LedgerRepository ledgerRepository,
    required IdGenerator idGenerator,
    required Clock clock,
  }) : _competition = competitionRepository,
       _scores = scoreRepository,
       _ledger = ledgerRepository,
       _ids = idGenerator,
       _clock = clock;

  final CompetitionRepository _competition;
  final ScoreRepository _scores;
  final LedgerRepository _ledger;
  final IdGenerator _ids;
  final Clock _clock;

  /// Posts round [roundId]'s scores to the ledger on behalf of admin
  /// [principal].
  Future<Result<List<PointEntry>>> call({
    required AuthenticatedUser principal,
    required String roundId,
  }) async {
    // Layer 1: platform authority. Only an admin (or service) may post points.
    final auth = Authorization.requireRole(principal, PlatformRole.admin);
    if (auth is Err<AuthenticatedUser>) {
      return Result.err(auth.error);
    }

    final roundIdResult = RoundId.tryParse(roundId);
    if (roundIdResult is Err<RoundId>) {
      return Result.err(roundIdResult.error);
    }
    final rId = (roundIdResult as Ok<RoundId>).value;

    // Layer 2 (business invariant): the round must exist and be scored.
    final roundResult = await _competition.findRound(rId);
    if (roundResult is Err<Round>) {
      return Result.err(roundResult.error);
    }
    final round = (roundResult as Ok<Round>).value;
    if (round.status != RoundStatus.scored) {
      return Result.err(
        AppError.invariant(
          'ledger.round_not_scored',
          'A round can be posted to the ledger only after it is scored '
              '(round is ${round.status.wireValue})',
        ),
      );
    }

    // Read the already-persisted scores (Scoring's output — never mutated here).
    final scoresResult = await _scores.listByRound(rId);
    if (scoresResult is Err<List<RoundScore>>) {
      return Result.err(scoresResult.error);
    }
    final roundScores = (scoresResult as Ok<List<RoundScore>>).value;

    // Build one round_score credit per participant. `now` is stamped once so
    // every entry in a single post shares an unambiguous occurred-at instant.
    final now = _clock.nowUtc();
    final entries = <PointEntry>[];
    for (final score in roundScores) {
      final idResult = PointEntryId.tryParse(_ids.newUuid());
      if (idResult is Err<PointEntryId>) {
        return Result.err(idResult.error);
      }
      final entryResult = PointEntry.create(
        id: (idResult as Ok<PointEntryId>).value,
        participantId: score.participantId,
        roundId: rId,
        kind: EntryKind.roundScore,
        amount: score.totalPoints,
        // Provenance: the originating round_score for this (participant, round).
        // Stable and audit-meaningful; distinct from the dedupe key so the same
        // handle re-derives on a replay without changing what is deduped.
        sourceRef: 'round_score:${rId.value}:${score.participantId.value}',
        occurredAt: now,
      );
      if (entryResult is Err<PointEntry>) {
        return Result.err(entryResult.error);
      }
      entries.add((entryResult as Ok<PointEntry>).value);
    }

    // Append atomically + idempotently. The adapter returns the subset actually
    // appended (empty on an idempotent replay); an empty batch is a no-op.
    return _ledger.appendEntries(entries);
  }
}
