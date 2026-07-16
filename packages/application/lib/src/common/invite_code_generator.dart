import 'package:domain/domain.dart';

/// Port for generating a fresh, unguessable [InviteCode] for a server-created
/// [Group] (Application ADR, Section 9: non-deterministic, side-effecting
/// concerns are ports implemented in Infrastructure).
///
/// The domain owns the invite code's *shape* (`InviteCode` — a fixed-length
/// string over a closed URL-safe alphabet) but must never perform the
/// non-deterministic randomness that produces one (Coding Standards ADR,
/// Section 1). A use-case obtains a fresh, already-typed [InviteCode] here — so
/// the generator, not the use-case, is responsible for drawing from
/// `InviteCode.alphabet` — keeping the use-case pure and testable (a fake yields
/// a fixed code).
///
/// Contract for implementations:
/// * MUST return an [InviteCode] whose value passes `InviteCode.tryParse`
///   (exactly `InviteCode.codeLength` characters, all in `InviteCode.alphabet`).
/// * MUST use a cryptographically-strong source of randomness (so a live code
///   cannot be predicted — decision #3, invite-only, no existence oracle).
/// * MUST NOT throw.
abstract interface class InviteCodeGenerator {
  /// Returns a fresh, well-formed [InviteCode].
  InviteCode newCode();
}
