import 'package:application/src/admin/audit_recorder.dart';
import 'package:application/src/identity/authorization.dart';
import 'package:application/src/ledger/ports/ledger_repository.dart';
import 'package:application/src/ledger/ports/participant_reader.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Query use-case: the narrow **cross-user read-for-support** — an admin reads a
/// SINGLE participant's ledger by explicit id (Admin Panel decision OPEN-A #3:
/// read-only, single participant by explicit id, never a bulk/export view, and
/// itself audited — the support read gets NO silent exemption from the trail).
///
/// This deliberately does NOT reuse `ReadParticipantLedger` (whose gate is
/// self-read ownership — a caller sees only their own ledger). The admin support
/// path is a *different* gate: the caller is an admin reading *someone else's*
/// ledger, which every prior read path forbade. That widening is exactly why
/// decision OPEN-A #3 was held open and then ratified narrow, and why every such
/// read is audited. Steps:
/// 1. authorize the caller as [PlatformRole.admin];
/// 2. parse the participant id and resolve it (a `null`/absent participant is a
///    typed not-found — `admin.participant_not_found`);
/// 3. record an immutable [AuditEntry] (`participant_ledger_viewed`) BEFORE
///    returning the data, so a completed read always leaves a trace (Security
///    ADR §2.4; a failed audit write refuses the read rather than silently
///    serving un-traced cross-user data);
/// 4. return the participant's append-only entry stream.
///
/// Never throws; returns the [PointEntry] stream as a typed [Result].
final class ViewParticipantLedger {
  /// Creates the use-case over its collaborators.
  const ViewParticipantLedger({
    required ParticipantReader participantReader,
    required LedgerRepository ledgerRepository,
    required AuditRecorder auditRecorder,
  }) : _participants = participantReader,
       _ledger = ledgerRepository,
       _audit = auditRecorder;

  final ParticipantReader _participants;
  final LedgerRepository _ledger;
  final AuditRecorder _audit;

  /// Returns the append-only [PointEntry] stream of [participantId] for the
  /// admin [principal], recording the support read in the audit trail. A
  /// [reason] is optional here (unlike a sanction) — decision OPEN-A #3 mandates
  /// the read be audited, not that it carry a justification string; when
  /// supplied it must be non-blank (`AuditEntry.create` enforces this).
  Future<Result<List<PointEntry>>> call({
    required AuthenticatedUser principal,
    required String participantId,
    String? reason,
  }) async {
    final auth = Authorization.requireRole(principal, PlatformRole.admin);
    if (auth is Err<AuthenticatedUser>) {
      return Result.err(auth.error);
    }

    final idResult = ParticipantId.tryParse(participantId);
    if (idResult is Err<ParticipantId>) {
      return Result.err(idResult.error);
    }
    final pId = (idResult as Ok<ParticipantId>).value;

    final found = await _participants.findParticipantById(pId);
    if (found is Err<Participant?>) {
      return Result.err(found.error);
    }
    final participant = (found as Ok<Participant?>).value;
    if (participant == null) {
      return const Result.err(
        AppError.invariant(
          'admin.participant_not_found',
          'No such participant to view',
        ),
      );
    }

    // Audit the support read BEFORE serving the data (§2.4): a completed
    // cross-user read always leaves an attributable trace.
    final audit = await _audit.record(
      actorId: principal.userId,
      action: AuditAction.participantLedgerViewed,
      targetRef: pId.value,
      reason: reason,
    );
    if (audit is Err<AuditEntry>) {
      return Result.err(audit.error);
    }

    return _ledger.listEntries(pId);
  }
}
