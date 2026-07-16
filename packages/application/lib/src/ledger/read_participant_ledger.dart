import 'package:application/src/identity/authorization.dart';
import 'package:application/src/ledger/ports/ledger_repository.dart';
import 'package:application/src/ledger/ports/participant_reader.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Query use-case: read a participant's **projected balance** and their
/// **append-only entry stream** — self-read only (Application ADR §2: query
/// separated from command; Security ADR §2: a caller sees only their own
/// ledger).
///
/// The visibility gate mirrors the Scoring read's discipline (Axiom 2, the
/// integrity boundary), specialized to the Ledger's ownership model: the ledger
/// is a participant's *personal* record of the points they have accrued, so the
/// gate is **ownership** — a caller may read only a participant they own. The
/// steps for both reads:
/// 1. authorize the caller holds at least the [PlatformRole.user] role;
/// 2. parse the participant id;
/// 3. resolve the participant via [ParticipantReader.findParticipantById] and
///    require that the caller's `userId` matches the participant's `userId`
///    (self-read). A missing participant, or one owned by someone else, is
///    reported identically as `ledger.participant_not_found` — the use-case
///    never reveals whether an id belongs to another user (no enumeration
///    oracle, Security ADR);
/// 4. delegate to the [LedgerRepository] for the projection / stream.
///
/// The balance is a **projection** over the append-only stream, never a mutable
/// stored number (Axiom 5) — the repository computes it and its value equals the
/// domain `LedgerBalance.project` over the same participant's entries.
///
/// Never throws; returns a typed [Result].
final class ReadParticipantLedger {
  /// Creates the use-case over its collaborators.
  const ReadParticipantLedger({
    required ParticipantReader participantReader,
    required LedgerRepository ledgerRepository,
  }) : _participants = participantReader,
       _ledger = ledgerRepository;

  final ParticipantReader _participants;
  final LedgerRepository _ledger;

  /// Returns the projected [LedgerBalance] of the participant [participantId],
  /// visible to [principal] only when they own that participant.
  Future<Result<LedgerBalance>> balanceOf({
    required AuthenticatedUser principal,
    required String participantId,
  }) async {
    final gate = await _gate(
      principal: principal,
      participantId: participantId,
    );
    if (gate is Err<ParticipantId>) {
      return Result.err(gate.error);
    }
    final pId = (gate as Ok<ParticipantId>).value;
    return _ledger.balanceFor(pId);
  }

  /// Returns the append-only [PointEntry] stream of the participant
  /// [participantId], visible to [principal] only when they own that
  /// participant.
  Future<Result<List<PointEntry>>> entriesOf({
    required AuthenticatedUser principal,
    required String participantId,
  }) async {
    final gate = await _gate(
      principal: principal,
      participantId: participantId,
    );
    if (gate is Err<ParticipantId>) {
      return Result.err(gate.error);
    }
    final pId = (gate as Ok<ParticipantId>).value;
    return _ledger.listEntries(pId);
  }

  /// Shared authorization + self-read ownership gate. Returns the validated
  /// [ParticipantId] on success, or the typed error to propagate.
  Future<Result<ParticipantId>> _gate({
    required AuthenticatedUser principal,
    required String participantId,
  }) async {
    final auth = Authorization.requireRole(principal, PlatformRole.user);
    if (auth is Err<AuthenticatedUser>) {
      return Result.err(auth.error);
    }

    final idResult = ParticipantId.tryParse(participantId);
    if (idResult is Err<ParticipantId>) {
      return Result.err(idResult.error);
    }
    final pId = (idResult as Ok<ParticipantId>).value;

    final participantResult = await _participants.findParticipantById(pId);
    if (participantResult is Err<Participant?>) {
      return Result.err(participantResult.error);
    }
    final participant = (participantResult as Ok<Participant?>).value;

    // Self-read: unknown id and foreign id are reported identically so the
    // response is not an ownership oracle (Security ADR §2).
    if (participant == null || participant.userId != principal.userId) {
      return const Result.err(
        AppError.authorization(
          'ledger.participant_not_found',
          'No such participant ledger is visible to this caller',
        ),
      );
    }

    return Result.ok(pId);
  }
}
