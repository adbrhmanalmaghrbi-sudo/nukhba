import 'package:application/src/common/clock.dart';
import 'package:application/src/common/id_generator.dart';
import 'package:application/src/common/invite_code_generator.dart';
import 'package:application/src/group/ports/group_repository.dart';
import 'package:application/src/identity/authorization.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Use-case: create a new [Group] (Application ADR, Section 2: a command
/// speaking a domain intent — `CreateGroup`, not a raw insert).
///
/// *Any* authenticated user ([PlatformRole.user] and above) may create a group —
/// this is the social-first entry point (Axiom 1): a user spins up a private
/// circle of friends, not an admin. The creator becomes the sole
/// [GroupRole.owner]; their owner membership is written **atomically** with the
/// group (decision #2) so a group can never exist without an owner row.
///
/// The principal owns the group as *themselves*: `ownerId` is taken from the
/// verified token, never from the request body, so a caller can never create a
/// group owned by someone else (Security ADR, Section 2).
///
/// Server-generated (never client-supplied): the group id, the owner
/// membership id, and the shareable [InviteCode] (decision #2/#3). Because all
/// three are generated fresh per invocation and the writes are atomic, a retried
/// create makes a *new* group (there is no natural idempotency key for "create a
/// group" — unlike join, which converges on `(groupId, userId)`).
///
/// Never throws; returns a typed [Result].
final class CreateGroup {
  /// Creates the use-case over its collaborators.
  const CreateGroup({
    required GroupRepository repository,
    required IdGenerator idGenerator,
    required InviteCodeGenerator inviteCodeGenerator,
    required Clock clock,
  }) : _repository = repository,
       _idGenerator = idGenerator,
       _inviteCodeGenerator = inviteCodeGenerator,
       _clock = clock;

  final GroupRepository _repository;
  final IdGenerator _idGenerator;
  final InviteCodeGenerator _inviteCodeGenerator;
  final Clock _clock;

  /// Creates a group named [name], owned by [principal].
  Future<Result<Group>> call({
    required AuthenticatedUser principal,
    required String name,
  }) async {
    // Layer 1: platform authority — any signed-in user.
    final auth = Authorization.requireRole(principal, PlatformRole.user);
    if (auth is Err<AuthenticatedUser>) {
      return Result.err(auth.error);
    }

    final groupIdResult = GroupId.tryParse(_idGenerator.newUuid());
    if (groupIdResult is Err<GroupId>) {
      return Result.err(groupIdResult.error);
    }
    final groupId = (groupIdResult as Ok<GroupId>).value;

    final now = _clock.nowUtc();
    final groupResult = Group.create(
      id: groupId,
      ownerId: principal.userId,
      name: name,
      inviteCode: _inviteCodeGenerator.newCode(),
      createdAt: now,
    );
    if (groupResult is Err<Group>) {
      return Result.err(groupResult.error);
    }
    final group = (groupResult as Ok<Group>).value;

    final membershipIdResult = GroupMembershipId.tryParse(
      _idGenerator.newUuid(),
    );
    if (membershipIdResult is Err<GroupMembershipId>) {
      return Result.err(membershipIdResult.error);
    }

    final ownerResult = GroupMembership.owner(
      id: (membershipIdResult as Ok<GroupMembershipId>).value,
      groupId: groupId,
      userId: principal.userId,
      joinedAt: now,
    );
    if (ownerResult is Err<GroupMembership>) {
      return Result.err(ownerResult.error);
    }
    final ownerMembership = (ownerResult as Ok<GroupMembership>).value;

    final saved = await _repository.createGroupWithOwner(
      group,
      ownerMembership,
    );
    return switch (saved) {
      Ok<void>() => Result.ok(group),
      Err<void>(:final error) => Result.err(error),
    };
  }
}
