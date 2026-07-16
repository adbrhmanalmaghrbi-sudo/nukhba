import 'dart:io';

import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import 'competition_route_harness.dart';
// ignore: always_use_package_imports
import '../../routes/groups/index.dart' as create_route;
// ignore: always_use_package_imports
import '../../routes/groups/join/index.dart' as join_route;
// ignore: always_use_package_imports
import '../../routes/groups/[id]/index.dart' as group_route;
// ignore: always_use_package_imports
import '../../routes/groups/[id]/members/index.dart' as members_route;
// ignore: always_use_package_imports
import '../../routes/groups/[id]/invite/regenerate/index.dart'
    as regenerate_route;
// ignore: always_use_package_imports
import '../../routes/groups/[id]/seasons/[seasonId]/leaderboard/index.dart'
    as group_leaderboard_route;

/// Route tests for the Groups surface — all seven routes, exercised through the
/// *real* wiring (`context.read<Future<CompositionRoot>>()` →
/// `root.<useCase>()`) over the in-memory [InMemoryGroupRepository] +
/// [InMemoryGroupStandingsReader] from [competition_route_harness]. This covers
/// the edge → use-case → domain → port path end-to-end, hermetically, mirroring
/// `season_leaderboard_test.dart` / `ledger_routes_test.dart`.
///
/// It is NOT a substitute for the infrastructure adapter's own tests
/// (infrastructure package) or the use-cases' own tests (application package):
/// its job is the route's status mapping, DTO shaping, path-param handling, and
/// that each authorization gate (member/owner/no-existence-oracle) is honoured
/// across the HTTP boundary.
void main() {
  // Builds a fresh root wiring every group use-case over a single shared pair of
  // in-memory repos, so a test can seed groups/memberships/standings and observe
  // the route's behaviour end-to-end. The scripted id/invite generators pin the
  // create/regenerate outputs deterministically.
  ({
    CompositionRoot root,
    InMemoryGroupRepository groups,
    InMemoryGroupStandingsReader standings,
  })
  rootFor({
    List<String> ids = const [kGroupId, kOwnerMembershipId],
    List<String> codes = const [kInviteCode],
  }) {
    final groups = InMemoryGroupRepository();
    final standings = InMemoryGroupStandingsReader();
    final idGen = ScriptedIdGenerator(ids);
    final clock = FixedClock(DateTime.utc(2026, 7, 11, 12));
    final inviteGen = ScriptedInviteCodeGenerator(codes);
    final root = CompositionRoot.forTesting(
      createGroup: CreateGroup(
        repository: groups,
        idGenerator: idGen,
        inviteCodeGenerator: inviteGen,
        clock: clock,
      ),
      getGroup: GetGroup(repository: groups),
      joinGroupByInvite: JoinGroupByInvite(
        repository: groups,
        idGenerator: idGen,
        clock: clock,
      ),
      renameGroup: RenameGroup(repository: groups),
      regenerateInvite: RegenerateInvite(
        repository: groups,
        inviteCodeGenerator: inviteGen,
      ),
      listGroupMembers: ListGroupMembers(repository: groups),
      getGroupLeaderboard: GetGroupLeaderboard(
        repository: groups,
        standingsReader: standings,
      ),
    );
    return (root: root, groups: groups, standings: standings);
  }

  /// Seeds a canonical group owned by [kOwnerUserId] with an owner membership,
  /// so member/owner-gated routes have a group to act on.
  void seedOwnedGroup(InMemoryGroupRepository repo) {
    repo
      ..seedGroup(storedGroup())
      ..seedMembership(
        storedMembership(
          id: kOwnerMembershipId,
          userId: kOwnerUserId,
          role: GroupRole.owner,
          joinedAt: DateTime.utc(2026, 7, 1),
        ),
      );
  }

  group('POST /groups (create)', () {
    test(
      'any authenticated user creates a group (200), member_count 1',
      () async {
        final setup = rootFor();

        final response = await create_route.onRequest(
          wireContext(
            root: setup.root,
            principal: ownerPrincipal(),
            body: {'name': 'The Circle'},
            method: HttpMethod.post,
          ),
        );

        expect(response.statusCode, HttpStatus.ok);
        final body = await decodeBody(response);
        expect(body['id'], kGroupId);
        expect(body['name'], 'The Circle');
        expect(body['owner_id'], kOwnerUserId);
        expect(body['invite_code'], kInviteCode);
        expect(body['member_count'], 1);
        // The owner membership was written atomically with the group.
        expect(setup.groups.memberships.length, 1);
        expect(setup.groups.memberships.single.role, GroupRole.owner);
        // No competition/season reference leaks onto the group (decision #1).
        expect(body.containsKey('season_id'), isFalse);
      },
    );

    test('a malformed/empty name is 400 (validation)', () async {
      final setup = rootFor();

      final response = await create_route.onRequest(
        wireContext(
          root: setup.root,
          principal: ownerPrincipal(),
          body: {'name': '   '},
          method: HttpMethod.post,
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
    });

    test('a missing name field is 400 (validation)', () async {
      final setup = rootFor();

      final response = await create_route.onRequest(
        wireContext(
          root: setup.root,
          principal: ownerPrincipal(),
          body: const <String, Object?>{},
          method: HttpMethod.post,
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
    });

    test('a transient storage failure is 503', () async {
      final setup = rootFor();
      setup.groups.failNextWith(
        const AppError.transient('group.row_corrupt', 'boom'),
      );

      final response = await create_route.onRequest(
        wireContext(
          root: setup.root,
          principal: ownerPrincipal(),
          body: {'name': 'The Circle'},
          method: HttpMethod.post,
        ),
      );

      expect(response.statusCode, HttpStatus.serviceUnavailable);
    });

    test('a non-POST method is 405', () async {
      final setup = rootFor();
      final response = await create_route.onRequest(
        wireContext(
          root: setup.root,
          principal: ownerPrincipal(),
          method: HttpMethod.get,
        ),
      );
      expect(response.statusCode, HttpStatus.methodNotAllowed);
    });
  });

  group('POST /groups/join', () {
    test('a user joins via a valid invite code (200) as member', () async {
      final setup = rootFor(ids: [kMemberMembershipId]);
      seedOwnedGroup(setup.groups);

      final response = await join_route.onRequest(
        wireContext(
          root: setup.root,
          principal: memberPrincipal(),
          body: {'invite_code': kInviteCode},
          method: HttpMethod.post,
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      final body = await decodeBody(response);
      expect(body['group_id'], kGroupId);
      expect(body['user_id'], kMemberUserId);
      expect(body['role'], 'member');
      // Owner + the newly-joined member.
      expect(setup.groups.memberships.length, 2);
    });

    test('joining is idempotent — a re-join returns one membership', () async {
      final setup = rootFor(ids: [kMemberMembershipId]);
      seedOwnedGroup(setup.groups);
      // Already a member.
      setup.groups.seedMembership(
        storedMembership(id: kMemberMembershipId, userId: kMemberUserId),
      );

      final response = await join_route.onRequest(
        wireContext(
          root: setup.root,
          principal: memberPrincipal(),
          body: {'invite_code': kInviteCode},
          method: HttpMethod.post,
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      final body = await decodeBody(response);
      expect(body['user_id'], kMemberUserId);
      // Owner + the one member row — no duplicate appended.
      expect(setup.groups.memberships.length, 2);
    });

    test('an unknown/rotated invite code is 409 group.invite_invalid '
        '(no existence oracle)', () async {
      final setup = rootFor(ids: [kMemberMembershipId]);
      seedOwnedGroup(setup.groups);

      final response = await join_route.onRequest(
        wireContext(
          root: setup.root,
          principal: memberPrincipal(),
          body: {'invite_code': kRotatedInviteCode},
          method: HttpMethod.post,
        ),
      );

      expect(response.statusCode, HttpStatus.conflict);
      expect((await decodeBody(response))['code'], 'group.invite_invalid');
    });

    test('a missing invite_code field is 400 (validation)', () async {
      final setup = rootFor();
      final response = await join_route.onRequest(
        wireContext(
          root: setup.root,
          principal: memberPrincipal(),
          body: const <String, Object?>{},
          method: HttpMethod.post,
        ),
      );
      expect(response.statusCode, HttpStatus.badRequest);
    });

    test('a non-POST method is 405', () async {
      final setup = rootFor();
      final response = await join_route.onRequest(
        wireContext(
          root: setup.root,
          principal: memberPrincipal(),
          method: HttpMethod.get,
        ),
      );
      expect(response.statusCode, HttpStatus.methodNotAllowed);
    });
  });

  group('GET /groups/{id}', () {
    test('a member reads the group (200) with the real member_count', () async {
      final setup = rootFor();
      seedOwnedGroup(setup.groups);
      // A second member so the count is > 1.
      setup.groups.seedMembership(
        storedMembership(id: kMemberMembershipId, userId: kMemberUserId),
      );

      final response = await group_route.onRequest(
        wireContext(
          root: setup.root,
          principal: ownerPrincipal(),
          method: HttpMethod.get,
        ),
        kGroupId,
      );

      expect(response.statusCode, HttpStatus.ok);
      final body = await decodeBody(response);
      expect(body['id'], kGroupId);
      expect(body['member_count'], 2);
      // The invite code is surfaced to a member (it is a capability they hold).
      expect(body['invite_code'], kInviteCode);
    });

    test(
      'a non-member is refused 401 group.not_a_member (no existence oracle)',
      () async {
        final setup = rootFor();
        seedOwnedGroup(setup.groups);

        final response = await group_route.onRequest(
          wireContext(
            root: setup.root,
            principal: nonMemberPrincipal(),
            method: HttpMethod.get,
          ),
          kGroupId,
        );

        expect(response.statusCode, HttpStatus.unauthorized);
        expect((await decodeBody(response))['code'], 'group.not_a_member');
      },
    );

    test(
      'an absent group is refused identically (401 group.not_a_member)',
      () async {
        final setup = rootFor();
        // Nothing seeded → the group does not exist; a non-member must not be
        // able to tell it apart from a private group they are not in.
        final response = await group_route.onRequest(
          wireContext(
            root: setup.root,
            principal: nonMemberPrincipal(),
            method: HttpMethod.get,
          ),
          kGroupId,
        );

        expect(response.statusCode, HttpStatus.unauthorized);
        expect((await decodeBody(response))['code'], 'group.not_a_member');
      },
    );

    test('a malformed group id is 400 (validation)', () async {
      final setup = rootFor();
      final response = await group_route.onRequest(
        wireContext(
          root: setup.root,
          principal: ownerPrincipal(),
          method: HttpMethod.get,
        ),
        'not-a-uuid',
      );
      expect(response.statusCode, HttpStatus.badRequest);
    });
  });

  group('PATCH /groups/{id} (rename)', () {
    test('the owner renames the group (200)', () async {
      final setup = rootFor();
      seedOwnedGroup(setup.groups);

      final response = await group_route.onRequest(
        wireContext(
          root: setup.root,
          principal: ownerPrincipal(),
          body: {'name': 'Renamed Circle'},
          method: HttpMethod.patch,
        ),
        kGroupId,
      );

      expect(response.statusCode, HttpStatus.ok);
      final body = await decodeBody(response);
      expect(body['name'], 'Renamed Circle');
      expect(body['member_count'], 1);
    });

    test('a non-owner member is refused 401 group.not_owner', () async {
      final setup = rootFor();
      seedOwnedGroup(setup.groups);
      setup.groups.seedMembership(
        storedMembership(id: kMemberMembershipId, userId: kMemberUserId),
      );

      final response = await group_route.onRequest(
        wireContext(
          root: setup.root,
          principal: memberPrincipal(),
          body: {'name': 'Hijack'},
          method: HttpMethod.patch,
        ),
        kGroupId,
      );

      expect(response.statusCode, HttpStatus.unauthorized);
      expect((await decodeBody(response))['code'], 'group.not_owner');
    });

    test('a non-member is refused 401 group.not_a_member', () async {
      final setup = rootFor();
      seedOwnedGroup(setup.groups);

      final response = await group_route.onRequest(
        wireContext(
          root: setup.root,
          principal: nonMemberPrincipal(),
          body: {'name': 'Hijack'},
          method: HttpMethod.patch,
        ),
        kGroupId,
      );

      expect(response.statusCode, HttpStatus.unauthorized);
      expect((await decodeBody(response))['code'], 'group.not_a_member');
    });

    test('a non-GET/PATCH method is 405', () async {
      final setup = rootFor();
      final response = await group_route.onRequest(
        wireContext(
          root: setup.root,
          principal: ownerPrincipal(),
          method: HttpMethod.delete,
        ),
        kGroupId,
      );
      expect(response.statusCode, HttpStatus.methodNotAllowed);
    });
  });

  group('GET /groups/{id}/members', () {
    test(
      'a member reads the roster (200) in joinedAt order, owner first',
      () async {
        final setup = rootFor();
        seedOwnedGroup(setup.groups);
        setup.groups.seedMembership(
          storedMembership(
            id: kMemberMembershipId,
            userId: kMemberUserId,
            joinedAt: DateTime.utc(2026, 7, 3),
          ),
        );

        final response = await members_route.onRequest(
          wireContext(
            root: setup.root,
            principal: memberPrincipal(),
            method: HttpMethod.get,
          ),
          kGroupId,
        );

        expect(response.statusCode, HttpStatus.ok);
        final body = await decodeBody(response);
        expect(body['group_id'], kGroupId);
        final members = (body['members']! as List)
            .cast<Map<Object?, Object?>>();
        expect(members.length, 2);
        // Owner joined 07-01, member 07-03 — owner first.
        expect(members[0]['user_id'], kOwnerUserId);
        expect(members[0]['role'], 'owner');
        expect(members[1]['user_id'], kMemberUserId);
        expect(members[1]['role'], 'member');
      },
    );

    test('a non-member is refused 401 group.not_a_member', () async {
      final setup = rootFor();
      seedOwnedGroup(setup.groups);

      final response = await members_route.onRequest(
        wireContext(
          root: setup.root,
          principal: nonMemberPrincipal(),
          method: HttpMethod.get,
        ),
        kGroupId,
      );

      expect(response.statusCode, HttpStatus.unauthorized);
      expect((await decodeBody(response))['code'], 'group.not_a_member');
    });

    test('a non-GET method is 405', () async {
      final setup = rootFor();
      final response = await members_route.onRequest(
        wireContext(
          root: setup.root,
          principal: memberPrincipal(),
          method: HttpMethod.post,
        ),
        kGroupId,
      );
      expect(response.statusCode, HttpStatus.methodNotAllowed);
    });
  });

  group('POST /groups/{id}/invite/regenerate', () {
    test('the owner rotates the invite code (200), old code revoked', () async {
      final setup = rootFor(codes: [kRotatedInviteCode]);
      seedOwnedGroup(setup.groups);

      final response = await regenerate_route.onRequest(
        wireContext(
          root: setup.root,
          principal: ownerPrincipal(),
          method: HttpMethod.post,
        ),
        kGroupId,
      );

      expect(response.statusCode, HttpStatus.ok);
      final body = await decodeBody(response);
      // The new code is surfaced; member_count is echoed (unchanged by rotation).
      expect(body['invite_code'], kRotatedInviteCode);
      expect(body['member_count'], 1);
      // The stored group now carries the rotated code — the old one is revoked.
      expect(
        setup.groups.groups[kGroupId]!.inviteCode.value,
        kRotatedInviteCode,
      );
    });

    test('a non-owner member is refused 401 group.not_owner', () async {
      final setup = rootFor(codes: [kRotatedInviteCode]);
      seedOwnedGroup(setup.groups);
      setup.groups.seedMembership(
        storedMembership(id: kMemberMembershipId, userId: kMemberUserId),
      );

      final response = await regenerate_route.onRequest(
        wireContext(
          root: setup.root,
          principal: memberPrincipal(),
          method: HttpMethod.post,
        ),
        kGroupId,
      );

      expect(response.statusCode, HttpStatus.unauthorized);
      expect((await decodeBody(response))['code'], 'group.not_owner');
    });

    test('a non-member is refused 401 group.not_a_member', () async {
      final setup = rootFor(codes: [kRotatedInviteCode]);
      seedOwnedGroup(setup.groups);

      final response = await regenerate_route.onRequest(
        wireContext(
          root: setup.root,
          principal: nonMemberPrincipal(),
          method: HttpMethod.post,
        ),
        kGroupId,
      );

      expect(response.statusCode, HttpStatus.unauthorized);
      expect((await decodeBody(response))['code'], 'group.not_a_member');
    });

    test('a non-POST method is 405', () async {
      final setup = rootFor();
      final response = await regenerate_route.onRequest(
        wireContext(
          root: setup.root,
          principal: ownerPrincipal(),
          method: HttpMethod.get,
        ),
        kGroupId,
      );
      expect(response.statusCode, HttpStatus.methodNotAllowed);
    });
  });

  group('GET /groups/{id}/seasons/{seasonId}/leaderboard', () {
    test(
      'a member reads the ranked group board (200), "1224" tie sharing',
      () async {
        final setup = rootFor();
        seedOwnedGroup(setup.groups);
        // Two more members so the group has three members ∩ season participants.
        setup.groups
          ..seedMembership(
            storedMembership(id: kMemberMembershipId, userId: kMemberUserId),
          )
          ..seedMembership(
            storedMembership(
              id: 'a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1',
              userId: kNonMemberUserId,
            ),
          );
        // Seed the unranked group∩season projection (non-sorted input order).
        setup.standings.seed(kGroupId, kSeasonId, [
          groupStanding(
            userId: kMemberUserId,
            participantId: kParticipantId,
            totalPoints: 5,
            joinedAt: DateTime.utc(2026, 7, 2),
          ),
          groupStanding(
            userId: kOwnerUserId,
            participantId: kParticipantId2,
            totalPoints: 9,
            entryCount: 3,
            joinedAt: DateTime.utc(2026, 7, 1),
          ),
          groupStanding(
            userId: kNonMemberUserId,
            participantId: 'a2a2a2a2-a2a2-a2a2-a2a2-a2a2a2a2a2a2',
            totalPoints: 5,
            joinedAt: DateTime.utc(2026, 7, 1),
          ),
        ]);

        final response = await group_leaderboard_route.onRequest(
          wireContext(
            root: setup.root,
            principal: ownerPrincipal(),
            method: HttpMethod.get,
          ),
          kGroupId,
          kSeasonId,
        );

        expect(response.statusCode, HttpStatus.ok);
        final body = await decodeBody(response);
        expect(body['group_id'], kGroupId);
        expect(body['season_id'], kSeasonId);
        final entries = (body['entries']! as List)
            .cast<Map<Object?, Object?>>();
        expect(entries.length, 3);

        // Rank 1: highest total (9), owner.
        expect(entries[0]['rank'], 1);
        expect(entries[0]['user_id'], kOwnerUserId);
        expect(entries[0]['participant_id'], kParticipantId2);
        expect(entries[0]['total_points'], 9);

        // Tie on 5 → both share rank 2; earlier joiner (07-01, nonMember pid)
        // displays before the 07-02 joiner.
        expect(entries[1]['rank'], 2);
        expect(entries[2]['rank'], 2);
        expect(entries[1]['user_id'], kNonMemberUserId);
        expect(entries[2]['user_id'], kMemberUserId);
      },
    );

    test(
      'an empty board is a legitimate 200 (no member is a participant)',
      () async {
        final setup = rootFor();
        seedOwnedGroup(setup.groups);
        // No standings seeded → the intersection is empty.

        final response = await group_leaderboard_route.onRequest(
          wireContext(
            root: setup.root,
            principal: ownerPrincipal(),
            method: HttpMethod.get,
          ),
          kGroupId,
          kSeasonId,
        );

        expect(response.statusCode, HttpStatus.ok);
        final body = await decodeBody(response);
        expect((body['entries']! as List), isEmpty);
      },
    );

    test('a non-member is refused 401 group.not_a_member', () async {
      final setup = rootFor();
      seedOwnedGroup(setup.groups);

      final response = await group_leaderboard_route.onRequest(
        wireContext(
          root: setup.root,
          principal: nonMemberPrincipal(),
          method: HttpMethod.get,
        ),
        kGroupId,
        kSeasonId,
      );

      expect(response.statusCode, HttpStatus.unauthorized);
      expect((await decodeBody(response))['code'], 'group.not_a_member');
    });

    test('a malformed season id is 400 (validation)', () async {
      final setup = rootFor();
      seedOwnedGroup(setup.groups);

      final response = await group_leaderboard_route.onRequest(
        wireContext(
          root: setup.root,
          principal: ownerPrincipal(),
          method: HttpMethod.get,
        ),
        kGroupId,
        'not-a-uuid',
      );

      expect(response.statusCode, HttpStatus.badRequest);
    });

    test('a non-GET method is 405', () async {
      final setup = rootFor();
      final response = await group_leaderboard_route.onRequest(
        wireContext(
          root: setup.root,
          principal: ownerPrincipal(),
          method: HttpMethod.post,
        ),
        kGroupId,
        kSeasonId,
      );
      expect(response.statusCode, HttpStatus.methodNotAllowed);
    });
  });
}
