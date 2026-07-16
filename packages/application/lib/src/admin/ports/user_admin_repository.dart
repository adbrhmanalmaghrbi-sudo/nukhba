import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Port for the admin user-sanction surface: resolve a platform [User] by id
/// and persist a lifecycle-status transition (Application ADR §9).
///
/// This is a **new, narrow port** justified exactly like the Ledger's
/// `ParticipantReader`: the ratified `UserDirectory` only offers
/// `ensureUser(principal)` (an idempotent upsert keyed on a *verified*
/// principal) — it has no "find an arbitrary user by id" or "update another
/// user's status" capability, and widening that frozen port would violate the
/// no-change-without-approval rule (Roadmap ADR §rules). `SuspendUser` /
/// `ReinstateUser` act on a TARGET user (by path id), who is not the caller, so
/// this port exposes the two operations they need. Infrastructure implements it
/// by reading/writing the same `identity.users` row the directory owns.
///
/// A new internal port inside the existing `application` package (no new
/// package), so `tooling/import_lint` is unaffected.
///
/// General contract (Application ADR §2):
/// * MUST NOT throw — every outcome is a typed [Result].
/// * MUST map infrastructure failures to [ErrorKind.transient].
abstract interface class UserAdminRepository {
  /// Returns the [User] identified by [id], or `Ok(null)` when no such user
  /// exists. The suspend/reinstate use-cases report a `null` as a typed
  /// not-found (never leaking whether the id was well-formed-but-absent).
  Future<Result<User?>> findUserById(UserId id);

  /// Persists [user] (an already-validated transition produced by
  /// `User.suspend()`/`reinstate()`), returning the stored value. The status is
  /// the only field the admin surface mutates; the adapter updates that column
  /// only. A driver failure maps to [ErrorKind.transient].
  Future<Result<User>> updateUser(User user);
}
