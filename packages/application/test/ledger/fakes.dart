import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// A complete in-memory [LedgerRepository] for use-case tests.
///
/// Reproduces the observable contract the Postgres adapter must honour:
/// * **append-only** — there is no mutate/delete surface, and an appended entry
///   is never edited in place;
/// * **idempotent** on the natural dedupe key `(participant_id, round_id,
///   entry_kind)` for a deduped kind ([EntryKind.isDedupedPerRound]) — a second
///   append of the same key is *skipped*, never duplicated, and is omitted from
///   the returned "actually appended" subset (so a replay reports nothing new);
/// * **atomic** — the batch is staged then committed in one shot, so a scripted
///   failure leaves the store untouched;
/// * **stream order** — [listEntries] returns occurred-at ascending, then entry
///   id, matching the port's documented order;
/// * **balance is a projection** — [balanceFor] computes via the domain
///   `LedgerBalance.project` over the same participant's entries, never a stored
///   mutable total.
///
/// It never throws.
final class FakeLedgerRepository implements LedgerRepository {
  /// All appended entries, keyed by their own id (append-only; entries are only
  /// ever inserted, never replaced or removed).
  final Map<String, PointEntry> _byId = {};

  /// The set of occupied dedupe keys for deduped kinds, so a re-post is skipped.
  final Set<String> _dedupeKeys = {};

  AppError? _scriptedFailure;

  /// Scripts the *next* call to fail with [error], then clears the script.
  void failNextWith(AppError error) => _scriptedFailure = error;

  AppError? _takeFailure() {
    final f = _scriptedFailure;
    _scriptedFailure = null;
    return f;
  }

  static String _dedupeKey(PointEntry e) =>
      '${e.participantId.value}|${e.roundId.value}|${e.kind.wireValue}';

  /// How many entries are stored in total (proves idempotent re-post appends no
  /// second crediting row).
  int get count => _byId.length;

  @override
  Future<Result<List<PointEntry>>> appendEntries(
    List<PointEntry> entries,
  ) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);

    // Stage first (atomic all-or-nothing): decide which entries are new, then
    // commit the whole batch in one shot.
    final toAppend = <PointEntry>[];
    final stagedKeys = <String>{};
    for (final e in entries) {
      if (e.kind.isDedupedPerRound) {
        final key = _dedupeKey(e);
        // Skip a key already present, or a duplicate within this same batch.
        if (_dedupeKeys.contains(key) || stagedKeys.contains(key)) {
          continue;
        }
        stagedKeys.add(key);
      }
      toAppend.add(e);
    }

    for (final e in toAppend) {
      _byId[e.id.value] = e;
      if (e.kind.isDedupedPerRound) {
        _dedupeKeys.add(_dedupeKey(e));
      }
    }
    return Result.ok(List<PointEntry>.unmodifiable(toAppend));
  }

  @override
  Future<Result<List<PointEntry>>> listEntries(
    ParticipantId participantId,
  ) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    final out =
        <PointEntry>[
          for (final e in _byId.values)
            if (e.participantId == participantId) e,
        ]..sort((a, b) {
          final byTime = a.occurredAt.compareTo(b.occurredAt);
          return byTime != 0 ? byTime : a.id.value.compareTo(b.id.value);
        });
    return Result.ok(out);
  }

  @override
  Future<Result<LedgerBalance>> balanceFor(ParticipantId participantId) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    final entriesResult = await listEntries(participantId);
    if (entriesResult is Err<List<PointEntry>>) {
      return Result.err(entriesResult.error);
    }
    final entries = (entriesResult as Ok<List<PointEntry>>).value;
    // The port guarantees balanceFor == LedgerBalance.project over listEntries.
    return LedgerBalance.project(
      participantId: participantId,
      entries: entries,
    );
  }
}

/// A complete in-memory [ParticipantReader] for use-case tests.
///
/// Resolves a participant by its own id, returning `Ok(null)` when unknown. It
/// never throws; a scripted transient failure proves propagation.
final class FakeParticipantReader implements ParticipantReader {
  final Map<String, Participant> _byId = {};

  AppError? _scriptedFailure;

  /// Scripts the *next* call to fail with [error], then clears the script.
  void failNextWith(AppError error) => _scriptedFailure = error;

  AppError? _takeFailure() {
    final f = _scriptedFailure;
    _scriptedFailure = null;
    return f;
  }

  /// Seeds a participant (tests arrange ownership state directly).
  void seed(Participant p) => _byId[p.id.value] = p;

  @override
  Future<Result<Participant?>> findParticipantById(ParticipantId id) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    return Result.ok(_byId[id.value]);
  }
}

// ---------------------------------------------------------------------------
// Builders shared across the ledger use-case tests.
// ---------------------------------------------------------------------------

/// Builds a stored round at [status] (ledger only cares about round id/status).
Round ledgerRound({
  required String id,
  required String seasonId,
  required RoundStatus status,
  int sequence = 1,
}) => Round.fromStored(
  id: RoundId(id),
  seasonId: SeasonId(seasonId),
  sequence: sequence,
  predictionDeadline: DateTime.utc(2026),
  status: status,
  ruleset:
      (RulesetSnapshot.create(payload: const {'points': 5}, rulesetVersion: 1)
              as Ok<RulesetSnapshot>)
          .value,
);

/// Builds a stored active participant.
Participant ledgerParticipant({
  required String id,
  required String seasonId,
  required String userId,
}) => Participant.fromStored(
  id: ParticipantId(id),
  seasonId: SeasonId(seasonId),
  userId: UserId(userId),
  status: ParticipantStatus.active,
  joinedAt: DateTime.utc(2026),
);

/// Builds a stored round score with a single fixture grade summing to [total].
RoundScore ledgerScore({
  required String roundId,
  required String participantId,
  required int total,
  int rulesetVersion = 1,
}) => RoundScore.fromStored(
  roundId: RoundId(roundId),
  participantId: ParticipantId(participantId),
  rulesetVersion: rulesetVersion,
  totalPoints: total,
  fixtureResults: [
    FixtureScoreResult(
      fixture: const FixtureRef('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
      grade: FixtureScoreGrade.exactScoreline,
      points: total,
    ),
  ],
);

/// Builds an already-appended point entry (tests arrange ledger state directly).
PointEntry ledgerEntry({
  required String id,
  required String participantId,
  required String roundId,
  required int amount,
  EntryKind kind = EntryKind.roundScore,
  String? sourceRef,
  DateTime? occurredAt,
}) => PointEntry.fromStored(
  id: PointEntryId(id),
  participantId: ParticipantId(participantId),
  roundId: RoundId(roundId),
  kind: kind,
  amount: amount,
  sourceRef: sourceRef ?? 'round_score:$roundId:$participantId',
  occurredAt: occurredAt ?? DateTime.utc(2026),
);
