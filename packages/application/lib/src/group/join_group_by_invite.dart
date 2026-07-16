import 'package:application/src/common/clock.dart';
import 'package:application/src/common/id_generator.dart';
import 'package:application/src/group/ports/group_repository.dart';
import 'package:application/src/identity/authorization.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Use-case: join a private group via its shareable invite code, creating a
/// [GroupMembership] (Application ADR, Section 2: command intent
/// `JoinGroupByInvite`).
///
/// *Any* authenticated user may join (Axiom 1, social-first; decision #2:
/// zero-friction instant join — no request/approve step). The invite code is
/// the **capability** (decision #3): possession of a valid code is what grants
/// access, so the code — not a group id — is the input, and an unknown/rotated
/// code is refused identically whether or not any group exists (no existence
/// oracle). The principal joins as *themselves*: the membership's `userId` comes
/// from the verified token, never the body (Security ADR, Section 2), so a
/// caller can never enrol someone else.
///
/// Idempotent (Application ADR, Section 2): if the user is already a member of
/// the resolved group, the existing [GroupMembership] is returned rather than
/// creating a duplicate or erroring — a retried join converges on one
/// membership. The storage-layer unique constraint on `(groupId, userId)` is the
/// backstop; a lost concurrent-join race is resolved by re-reading (mirroring
/// `JoinCompetition`).
///
/// The owner is already a member (created with the group), so an owner "joining"
/// their own group via the code is a no-op that returns their owner membership.
///
/// Never throws; returns a typed [Result].
final class JoinGroupByInvite {
  /// Creates the use-case over its collaborators.
  const JoinGroupByInvite({
    required GroupRepository repository,
    required IdGenerator idGenerator,
    required Clock clock,
  }) : _repository = repository,
       _idGenerator = idGenerator,
       _clock = clock;

  final GroupRepository _repository;
  final IdGenerator _idGenerator;
  final Clock _clock;

  /// Joins [principal] to the group identified by [inviteCode].
  Future<Result<GroupMembership>> call({
    required AuthenticatedUser principal,
    required String inviteCode,
  }) async {
    final auth = Authorization.requireRole(principal, PlatformRole.user);
    if (auth is Err<AuthenticatedUser>) {
      return Result.err(auth.error);
    }

    final codeResult = InviteCode.tryParse(inviteCode);
    if (codeResult is Err<InviteCode>) {
      return Result.err(codeResult.error);
    }
    final code = (codeResult as Ok<InviteCode>).value;

    // Resolve the group by its capability code. An unknown/rotated code is
    // refused with a code that leaks no group existence (decision #3).
    final groupResult = await _repository.findByInviteCode(code);
    if (groupResult is Err<Group?>) {
      return Result.err(groupResult.error);
    }
    final group = (groupResult as Ok<Group?>).value;
    if (group == null) {
      return Result.err(
        const AppError.invariant(
          'group.invite_invalid',
          'The invite code is not valid',
        ),
      );
    }

    // Idempotency: return the existing membership if the user already belongs
    // (this also covers the owner, whose membership was created with the group).
    final existing = await _repository.findMembership(
      group.id,
      principal.userId,
    );
    switch (existing) {
      case Ok<GroupMembership?>(:final value):
        if (value != null) {
          return Result.ok(value);
        }
      case Err<GroupMembership?>(:final error):
        return Result.err(error);
    }

    final membershipIdResult = GroupMembershipId.tryParse(
      _idGenerator.newUuid(),
    );
    if (membershipIdResult is Err<GroupMembershipId>) {
      return Result.err(membershipIdResult.error);
    }

    final membershipResult = GroupMembership.join(
      id: (membershipIdResult as Ok<GroupMembershipId>).value,
      groupId: group.id,
      userId: principal.userId,
      joinedAt: _clock.nowUtc(),
    );
    if (membershipResult is Err<GroupMembership>) {
      return Result.err(membershipResult.error);
    }
    final membership = (membershipResult as Ok<GroupMembership>).value;

    final saved = await _repository.saveMembership(membership);
    return switch (saved) {
      Ok<void>() => Result.ok(membership),
      Err<void>(:final error) => await _resolveConflict(
        error,
        group.id,
        principal.userId,
      ),
    };
  }

  /// On a unique-violation conflict from a concurrent join, re-read the winning
  /// membership so the caller still gets a successful, idempotent result. Any
  /// other error is propagated unchanged.
  Future<Result<GroupMembership>> _resolveConflict(
    AppError error,
    GroupId groupId,
    UserId userId,
  ) async {
    if (error.code != 'group.already_member') {
      return Result.err(error);
    }
    final reread = await _repository.findMembership(groupId, userId);
    return switch (reread) {
      Ok<GroupMembership?>(:final value) =>
        value != null ? Result.ok(value) : Result.err(error),
      Err<GroupMembership?>(:final error) => Result.err(error),
    };
  }
}
