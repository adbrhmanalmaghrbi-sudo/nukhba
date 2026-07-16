import 'package:application/src/common/clock.dart';
import 'package:application/src/common/id_generator.dart';
import 'package:application/src/competition/ports/competition_repository.dart';
import 'package:application/src/identity/authorization.dart';
import 'package:application/src/prediction/ports/prediction_repository.dart';
import 'package:application/src/prediction/prediction_view.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// One fixture's predicted scoreline as it arrives from the client — a raw,
/// untrusted intent (Application ADR, Section 2: commands speak in domain
/// intents, validated server-side). The use-case turns each of these into a
/// validated [FixtureScorePrediction]; the client never constructs domain
/// value objects (Axioms 2/5).
final class FixtureScoreInput {
  /// Creates a raw fixture-score input.
  const FixtureScoreInput({
    required this.fixtureId,
    required this.homeGoals,
    required this.awayGoals,
  });

  /// The referenced fixture id (untrusted; validated via [FixtureRef.tryParse]).
  final String fixtureId;

  /// The predicted goals for the home side (untrusted; range-checked by the
  /// domain value object).
  final int homeGoals;

  /// The predicted goals for the away side (untrusted; range-checked).
  final int awayGoals;
}

/// Use-case: submit (or amend) a participant's prediction for a round
/// (Application ADR, Section 2: command intent `SubmitPrediction`).
///
/// This is the platform's highest-volume integrity-critical write, so the
/// Prediction aggregate is kept separate from Competition (Database ADR,
/// Sections 1 & 2.1). The principal predicts as *themselves*: the participant
/// is resolved server-side from the verified token and the round's season,
/// never from the request body, so a caller can never predict on someone
/// else's behalf (Security ADR, Section 2 / Axiom 2). Points are never accepted
/// or computed here — the client submits only intent (Axioms 2/5).
///
/// Business invariants enforced (in order):
/// 1. **Round is open.** Submitting/amending after lock is rejected — the
///    domain [Prediction.submit]/[Prediction.amend] guard is the primary check,
///    the migration's check constraint the backstop (Axiom 6).
/// 2. **Every predicted fixture belongs to the round** (product decision,
///    2026-07-10): a score whose `FixtureRef` isn't among the round's
///    `RoundFixture` links is rejected `prediction.fixture_not_in_round`.
/// 3. **The forecast is complete** (product decision, 2026-07-10): the submitted
///    fixture-id set must equal the round's full linked-fixture set exactly —
///    no missing fixture, no extra — else `prediction.incomplete_forecast`.
///    This completeness rule lives here, not in the domain entity, because only
///    the use-case can see the round's fixture list.
///
/// **Idempotent** (Application ADR, Section 2): a first call for a
/// `(round, participant)` inserts; a repeat call amends the existing prediction
/// in place (one row, Axiom 4). A concurrent duplicate insert that loses the
/// race converges by re-reading and amending.
///
/// Never throws; returns a typed [Result].
final class SubmitPrediction {
  /// Creates the use-case over its collaborators.
  const SubmitPrediction({
    required PredictionRepository predictionRepository,
    required CompetitionRepository competitionRepository,
    required IdGenerator idGenerator,
    required Clock clock,
  }) : _predictions = predictionRepository,
       _competition = competitionRepository,
       _idGenerator = idGenerator,
       _clock = clock;

  final PredictionRepository _predictions;
  final CompetitionRepository _competition;
  final IdGenerator _idGenerator;
  final Clock _clock;

  /// Submits [scores] as [principal]'s prediction for round [roundId].
  ///
  /// On success returns a [PredictionView] carrying the persisted prediction
  /// **and** the exact UTC instant this call stamped it under (the clock read
  /// once below), so the edge can build a faithful versioned `PredictionDto`
  /// without ever fabricating a timestamp (Axioms 2/5).
  Future<Result<PredictionView>> call({
    required AuthenticatedUser principal,
    required String roundId,
    required List<FixtureScoreInput> scores,
  }) async {
    // Layer 1: any authenticated user may predict (social-first entry, Axiom 1).
    final auth = Authorization.requireRole(principal, PlatformRole.user);
    if (auth is Err<AuthenticatedUser>) {
      return Result.err(auth.error);
    }

    final roundIdResult = RoundId.tryParse(roundId);
    if (roundIdResult is Err<RoundId>) {
      return Result.err(roundIdResult.error);
    }
    final rId = (roundIdResult as Ok<RoundId>).value;

    // Load the round: it must exist and still be open.
    final roundResult = await _competition.findRound(rId);
    if (roundResult is Err<Round>) {
      return Result.err(roundResult.error);
    }
    final round = (roundResult as Ok<Round>).value;
    if (!round.status.isOpen) {
      return Result.err(
        AppError.invariant(
          'prediction.round_not_open',
          'Predictions can only be submitted while the round is open '
              '(round is ${round.status.wireValue})',
        ),
      );
    }

    // Resolve the caller's participant in this round's season. A user must have
    // joined the season before predicting; absence is a business precondition
    // failure, not a permission error.
    final participantResult = await _competition.findParticipant(
      round.seasonId,
      principal.userId,
    );
    if (participantResult is Err<Participant?>) {
      return Result.err(participantResult.error);
    }
    final participant = (participantResult as Ok<Participant?>).value;
    if (participant == null) {
      return Result.err(
        const AppError.invariant(
          'prediction.not_a_participant',
          'You must join the season before submitting a prediction',
        ),
      );
    }

    // Load the round's fixture composition (the completeness reference).
    final fixturesResult = await _predictions.listRoundFixtures(rId);
    if (fixturesResult is Err<List<RoundFixture>>) {
      return Result.err(fixturesResult.error);
    }
    final roundFixtures = (fixturesResult as Ok<List<RoundFixture>>).value;
    final requiredFixtureIds = <String>{
      for (final link in roundFixtures) link.fixture.value,
    };
    if (requiredFixtureIds.isEmpty) {
      return Result.err(
        const AppError.invariant(
          'prediction.round_has_no_fixtures',
          'The round has no fixtures to predict',
        ),
      );
    }

    // Validate every raw score into a domain value object (range + shape).
    final domainScores = <FixtureScorePrediction>[];
    final submittedFixtureIds = <String>{};
    for (final input in scores) {
      final fixtureResult = FixtureRef.tryParse(input.fixtureId);
      if (fixtureResult is Err<FixtureRef>) {
        return Result.err(fixtureResult.error);
      }
      final fixture = (fixtureResult as Ok<FixtureRef>).value;

      // Rule 2: the fixture must belong to the round.
      if (!requiredFixtureIds.contains(fixture.value)) {
        return Result.err(
          AppError.validation(
            'prediction.fixture_not_in_round',
            'Fixture ${fixture.value} is not part of this round',
          ),
        );
      }

      final scoreResult = FixtureScorePrediction.create(
        fixture: fixture,
        homeGoals: input.homeGoals,
        awayGoals: input.awayGoals,
      );
      if (scoreResult is Err<FixtureScorePrediction>) {
        return Result.err(scoreResult.error);
      }
      domainScores.add((scoreResult as Ok<FixtureScorePrediction>).value);
      submittedFixtureIds.add(fixture.value);
    }

    // Rule 3: the submission must cover exactly the round's fixtures — no
    // missing (a duplicate would have shrunk this set) and no extra (excluded
    // by Rule 2 above). Comparing the deduped submitted set against the
    // required set catches both "too few distinct fixtures" and duplicates.
    if (submittedFixtureIds.length != requiredFixtureIds.length ||
        !submittedFixtureIds.containsAll(requiredFixtureIds)) {
      return Result.err(
        const AppError.validation(
          'prediction.incomplete_forecast',
          'A prediction must cover every fixture in the round exactly once',
        ),
      );
    }

    // Idempotency: amend an existing prediction, otherwise insert a new one.
    final existingResult = await _predictions.findByRoundAndParticipant(
      rId,
      participant.id,
    );
    if (existingResult is Err<PredictionView?>) {
      return Result.err(existingResult.error);
    }
    final existing = (existingResult as Ok<PredictionView?>).value;
    final now = _clock.nowUtc();

    if (existing != null) {
      return _amend(existing.prediction, round.status, domainScores, now);
    }
    return _insert(rId, participant.id, round.status, domainScores, now);
  }

  Future<Result<PredictionView>> _insert(
    RoundId roundId,
    ParticipantId participantId,
    RoundStatus roundStatus,
    List<FixtureScorePrediction> scores,
    DateTime now,
  ) async {
    final idResult = PredictionId.tryParse(_idGenerator.newUuid());
    if (idResult is Err<PredictionId>) {
      return Result.err(idResult.error);
    }

    final predictionResult = Prediction.submit(
      id: (idResult as Ok<PredictionId>).value,
      roundId: roundId,
      participantId: participantId,
      roundStatus: roundStatus,
      scores: scores,
    );
    if (predictionResult is Err<Prediction>) {
      return Result.err(predictionResult.error);
    }
    final prediction = (predictionResult as Ok<Prediction>).value;

    final saved = await _predictions.save(prediction, now);
    return switch (saved) {
      // The instant we stamped (`now`) is exactly the row's `submitted_at`.
      Ok<void>() => Result.ok(
        PredictionView(prediction: prediction, submittedAt: now),
      ),
      // A concurrent first submission won the race; converge by amending it.
      Err<void>(:final error) =>
        error.code == 'prediction.already_submitted'
            ? await _resolveConflictThenAmend(
                roundId,
                participantId,
                roundStatus,
                scores,
                now,
                error,
              )
            : Result.err(error),
    };
  }

  Future<Result<PredictionView>> _amend(
    Prediction existing,
    RoundStatus roundStatus,
    List<FixtureScorePrediction> scores,
    DateTime now,
  ) async {
    final amendedResult = existing.amend(
      roundStatus: roundStatus,
      scores: scores,
    );
    if (amendedResult is Err<Prediction>) {
      return Result.err(amendedResult.error);
    }
    final amended = (amendedResult as Ok<Prediction>).value;

    final updated = await _predictions.update(amended, now);
    return switch (updated) {
      // `update` refreshes `submitted_at` to `now` (Axiom 4: same row).
      Ok<void>() => Result.ok(
        PredictionView(prediction: amended, submittedAt: now),
      ),
      Err<void>(:final error) => Result.err(error),
    };
  }

  Future<Result<PredictionView>> _resolveConflictThenAmend(
    RoundId roundId,
    ParticipantId participantId,
    RoundStatus roundStatus,
    List<FixtureScorePrediction> scores,
    DateTime now,
    AppError insertError,
  ) async {
    final reread = await _predictions.findByRoundAndParticipant(
      roundId,
      participantId,
    );
    return switch (reread) {
      Ok<PredictionView?>(:final value) =>
        value != null
            ? await _amend(value.prediction, roundStatus, scores, now)
            : Result.err(insertError),
      Err<PredictionView?>(:final error) => Result.err(error),
    };
  }
}
