import 'dart:io';

import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import 'competition_route_harness.dart';
// ignore: always_use_package_imports
import '../../routes/groups/[id]/rounds/[roundId]/reactions/index.dart'
    as reactions_route;
// ignore: always_use_package_imports
import '../../routes/groups/[id]/feed/index.dart' as feed_route;

/// Route tests for the Social (Tier-3) surface — the reactions route (`PUT` /
/// `DELETE` / `GET` on `/groups/{id}/rounds/{roundId}/reactions`) and the
/// activity-feed route (`GET /groups/{id}/feed`), exercised through the *real*
/// wiring (`context.read<Future<CompositionRoot>>()` → `root.<useCase>()`) over
/// the in-memory [InMemoryReactionRepository] + [InMemoryActivityFeedReader] +
/// [InMemoryGroupRepository] from [competition_route_harness]. This covers the
/// edge → use-case → domain → port path end-to-end, hermetically, mirroring
/// `group_routes_test.dart` / `ledger_routes_test.dart`.
///
/// It is NOT a substitute for the infrastructure adapters' own tests
/// (infrastructure package) or the use-cases' own tests (application package):
/// its job is the route's status mapping, DTO shaping, path-param handling, and
/// that each authorization gate (the member-only `group.not_a_member`
/// no-existence-oracle gate — Social decision #3) is honoured across the HTTP
/// boundary, plus the feed's `?limit=` clamp reaching the reader (decision #4).
void main() {
  // Builds a fresh root wiring the four Social use-cases over one shared trio of
  // in-memory repos, so a test can seed memberships/reactions/feed events and
  // observe the route behaviour end-to-end. The scripted id generator pins the
  // created reaction id; the clock pins reactedAt.
  ({
    CompositionRoot root,
    InMemoryReactionRepository reactions,
    InMemoryActivityFeedReader feed,
    InMemoryGroupRepository groups,
  })
  rootFor({List<String> ids = const [kReactionId, kReactionId2]}) {
    final reactions = InMemoryReactionRepository();
    final feed = InMemoryActivityFeedReader();
    final groups = InMemoryGroupRepository();
    final idGen = ScriptedIdGenerator(ids);
    final clock = FixedClock(DateTime.utc(2026, 7, 12, 12));
    final root = CompositionRoot.forTesting(
      reactToRound: ReactToRound(
        reactions: reactions,
        groups: groups,
        idGenerator: idGen,
        clock: clock,
      ),
      removeReaction: RemoveReaction(reactions: reactions, groups: groups),
      listRoundReactions: ListRoundReactions(
        reactions: reactions,
        groups: groups,
      ),
      getGroupActivityFeed: GetGroupActivityFeed(feed: feed, groups: groups),
    );
    return (root: root, reactions: reactions, feed: feed, groups: groups);
  }

  /// Seeds a membership for [userId] in the canonical group, so a
  /// member-gated route has a member to act as.
  void seedMember(
    InMemoryGroupRepository repo,
    String userId, {
    GroupRole role = GroupRole.member,
  }) {
    repo.seedMembership(
      storedMembership(
        id: kMemberMembershipId,
        userId: userId,
        role: role,
        joinedAt: DateTime.utc(2026, 7, 1),
      ),
    );
  }

  group('PUT /groups/{id}/rounds/{roundId}/reactions (react)', () {
    test('a member reacts (200), one row, author from the token', () async {
      final setup = rootFor();
      seedMember(setup.groups, kMemberUserId);

      final response = await reactions_route.onRequest(
        wireContext(
          root: setup.root,
          principal: memberPrincipal(),
          body: {'emoji': 'fire'},
          method: HttpMethod.put,
        ),
        kGroupId,
        kRoundId,
      );

      expect(response.statusCode, HttpStatus.ok);
      final body = await decodeBody(response);
      expect(body['id'], kReactionId);
      expect(body['group_id'], kGroupId);
      expect(body['round_id'], kRoundId);
      // The author is bound from the verified token, never the body.
      expect(body['user_id'], kMemberUserId);
      expect(body['emoji'], 'fire');
      expect(setup.reactions.reactions.length, 1);
      // No points field ever leaks onto a reaction (Axiom 5).
      expect(body.containsKey('points'), isFalse);
    });

    test(
      'a member re-reacting swaps the emoji in place — still one row',
      () async {
        final setup = rootFor();
        seedMember(setup.groups, kMemberUserId);
        setup.reactions.seed(storedReaction(userId: kMemberUserId));

        final response = await reactions_route.onRequest(
          wireContext(
            root: setup.root,
            principal: memberPrincipal(),
            body: {'emoji': 'clap'},
            method: HttpMethod.put,
          ),
          kGroupId,
          kRoundId,
        );

        expect(response.statusCode, HttpStatus.ok);
        final body = await decodeBody(response);
        expect(body['emoji'], 'clap');
        // Swapped in place — never a second row (decision #2).
        expect(setup.reactions.reactions.length, 1);
        expect(setup.reactions.reactions.single.emoji.wireValue, 'clap');
      },
    );

    test('an unknown emoji token is 400 (validation)', () async {
      final setup = rootFor();
      seedMember(setup.groups, kMemberUserId);

      final response = await reactions_route.onRequest(
        wireContext(
          root: setup.root,
          principal: memberPrincipal(),
          body: {'emoji': 'thumbsdown'},
          method: HttpMethod.put,
        ),
        kGroupId,
        kRoundId,
      );

      expect(response.statusCode, HttpStatus.badRequest);
      final body = await decodeBody(response);
      expect(body['code'], 'social.reaction_emoji_unknown');
      expect(setup.reactions.reactions, isEmpty);
    });

    test('a missing emoji field is 400 (validation)', () async {
      final setup = rootFor();
      seedMember(setup.groups, kMemberUserId);

      final response = await reactions_route.onRequest(
        wireContext(
          root: setup.root,
          principal: memberPrincipal(),
          body: <String, Object?>{},
          method: HttpMethod.put,
        ),
        kGroupId,
        kRoundId,
      );

      expect(response.statusCode, HttpStatus.badRequest);
    });

    test(
      'a non-member is refused 401 group.not_a_member (no oracle)',
      () async {
        final setup = rootFor();
        // No membership seeded for the non-member.

        final response = await reactions_route.onRequest(
          wireContext(
            root: setup.root,
            principal: nonMemberPrincipal(),
            body: {'emoji': 'fire'},
            method: HttpMethod.put,
          ),
          kGroupId,
          kRoundId,
        );

        expect(response.statusCode, HttpStatus.unauthorized);
        final body = await decodeBody(response);
        expect(body['code'], 'group.not_a_member');
        expect(setup.reactions.reactions, isEmpty);
      },
    );

    test('a malformed group id is 400 (validation)', () async {
      final setup = rootFor();

      final response = await reactions_route.onRequest(
        wireContext(
          root: setup.root,
          principal: memberPrincipal(),
          body: {'emoji': 'fire'},
          method: HttpMethod.put,
        ),
        'not-a-uuid',
        kRoundId,
      );

      expect(response.statusCode, HttpStatus.badRequest);
    });

    test('a transient repository failure is 503 (Tier-3 confined)', () async {
      final setup = rootFor();
      seedMember(setup.groups, kMemberUserId);
      setup.reactions.failNextWith(
        const AppError.transient('social.row_corrupt', 'boom'),
      );

      final response = await reactions_route.onRequest(
        wireContext(
          root: setup.root,
          principal: memberPrincipal(),
          body: {'emoji': 'fire'},
          method: HttpMethod.put,
        ),
        kGroupId,
        kRoundId,
      );

      expect(response.statusCode, HttpStatus.serviceUnavailable);
    });
  });

  group('DELETE /groups/{id}/rounds/{roundId}/reactions (remove)', () {
    test('a member removing their own reaction is 200 removed:true', () async {
      final setup = rootFor();
      seedMember(setup.groups, kMemberUserId);
      setup.reactions.seed(storedReaction(userId: kMemberUserId));

      final response = await reactions_route.onRequest(
        wireContext(
          root: setup.root,
          principal: memberPrincipal(),
          method: HttpMethod.delete,
        ),
        kGroupId,
        kRoundId,
      );

      expect(response.statusCode, HttpStatus.ok);
      final body = await decodeBody(response);
      expect(body['removed'], isTrue);
      expect(setup.reactions.reactions, isEmpty);
    });

    test('removing an absent reaction is a 200 no-op removed:false', () async {
      final setup = rootFor();
      seedMember(setup.groups, kMemberUserId);

      final response = await reactions_route.onRequest(
        wireContext(
          root: setup.root,
          principal: memberPrincipal(),
          method: HttpMethod.delete,
        ),
        kGroupId,
        kRoundId,
      );

      expect(response.statusCode, HttpStatus.ok);
      final body = await decodeBody(response);
      expect(body['removed'], isFalse);
    });

    test('a non-member is refused 401 group.not_a_member', () async {
      final setup = rootFor();

      final response = await reactions_route.onRequest(
        wireContext(
          root: setup.root,
          principal: nonMemberPrincipal(),
          method: HttpMethod.delete,
        ),
        kGroupId,
        kRoundId,
      );

      expect(response.statusCode, HttpStatus.unauthorized);
      final body = await decodeBody(response);
      expect(body['code'], 'group.not_a_member');
    });
  });

  group('GET /groups/{id}/rounds/{roundId}/reactions (list)', () {
    test(
      'a member reads the round reactions (200), reactedAt-ordered',
      () async {
        final setup = rootFor();
        seedMember(setup.groups, kMemberUserId);
        setup.reactions
          ..seed(
            storedReaction(
              id: kReactionId2,
              userId: kOwnerUserId,
              emoji: ReactionKind.laugh,
              reactedAt: DateTime.utc(2026, 7, 12, 10),
            ),
          )
          ..seed(
            storedReaction(
              userId: kMemberUserId,
              reactedAt: DateTime.utc(2026, 7, 12, 8),
            ),
          );

        final response = await reactions_route.onRequest(
          wireContext(
            root: setup.root,
            principal: memberPrincipal(),
            method: HttpMethod.get,
          ),
          kGroupId,
          kRoundId,
        );

        expect(response.statusCode, HttpStatus.ok);
        final body = await decodeBody(response);
        expect(body['group_id'], kGroupId);
        expect(body['round_id'], kRoundId);
        final list = body['reactions']! as List<Object?>;
        expect(list.length, 2);
        // reactedAt ascending: the 08:00 reaction precedes the 10:00 one.
        expect((list.first! as Map)['user_id'], kMemberUserId);
        expect((list.last! as Map)['user_id'], kOwnerUserId);
      },
    );

    test('an empty round is a legitimate empty list (200)', () async {
      final setup = rootFor();
      seedMember(setup.groups, kMemberUserId);

      final response = await reactions_route.onRequest(
        wireContext(
          root: setup.root,
          principal: memberPrincipal(),
          method: HttpMethod.get,
        ),
        kGroupId,
        kRoundId,
      );

      expect(response.statusCode, HttpStatus.ok);
      final body = await decodeBody(response);
      expect(body['reactions'], isEmpty);
    });

    test('a non-member is refused 401 group.not_a_member', () async {
      final setup = rootFor();

      final response = await reactions_route.onRequest(
        wireContext(
          root: setup.root,
          principal: nonMemberPrincipal(),
          method: HttpMethod.get,
        ),
        kGroupId,
        kRoundId,
      );

      expect(response.statusCode, HttpStatus.unauthorized);
      final body = await decodeBody(response);
      expect(body['code'], 'group.not_a_member');
    });
  });

  test(
    'reactions route rejects a non-PUT/DELETE/GET method with 405',
    () async {
      final setup = rootFor();

      final response = await reactions_route.onRequest(
        wireContext(
          root: setup.root,
          principal: memberPrincipal(),
          method: HttpMethod.patch,
        ),
        kGroupId,
        kRoundId,
      );

      expect(response.statusCode, HttpStatus.methodNotAllowed);
    },
  );

  group('GET /groups/{id}/feed (activity feed)', () {
    test('a member reads the feed (200), newest-first', () async {
      final setup = rootFor();
      seedMember(setup.groups, kMemberUserId);
      setup.feed.seed(kGroupId, [
        ActivityEvent.memberJoined(
          groupId: GroupId(kGroupId),
          userId: UserId(kMemberUserId),
          occurredAt: DateTime.utc(2026, 7, 10),
        ),
        ActivityEvent.roundScored(
          groupId: GroupId(kGroupId),
          roundId: RoundId(kRoundId),
          occurredAt: DateTime.utc(2026, 7, 12),
        ),
      ]);

      final response = await feed_route.onRequest(
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
      final events = body['events']! as List<Object?>;
      expect(events.length, 2);
      // Newest-first: the 2026-07-12 round_scored precedes the 2026-07-10 join.
      expect((events.first! as Map)['type'], 'round_scored');
      expect((events.first! as Map)['round_id'], kRoundId);
      expect((events.last! as Map)['type'], 'member_joined');
      expect((events.last! as Map)['user_id'], kMemberUserId);
    });

    test('an empty feed is a legitimate empty list (200)', () async {
      final setup = rootFor();
      seedMember(setup.groups, kMemberUserId);

      final response = await feed_route.onRequest(
        wireContext(
          root: setup.root,
          principal: memberPrincipal(),
          method: HttpMethod.get,
        ),
        kGroupId,
      );

      expect(response.statusCode, HttpStatus.ok);
      final body = await decodeBody(response);
      expect(body['events'], isEmpty);
    });

    test('an in-range ?limit= reaches the reader as-is (clamp)', () async {
      final setup = rootFor();
      seedMember(setup.groups, kMemberUserId);

      final response = await feed_route.onRequest(
        wireContext(
          root: setup.root,
          principal: memberPrincipal(),
          method: HttpMethod.get,
          queryParameters: const {'limit': '10'},
        ),
        kGroupId,
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(setup.feed.lastLimit, 10);
    });

    test('an over-cap ?limit= is clamped to maxLimit at the reader', () async {
      final setup = rootFor();
      seedMember(setup.groups, kMemberUserId);

      final response = await feed_route.onRequest(
        wireContext(
          root: setup.root,
          principal: memberPrincipal(),
          method: HttpMethod.get,
          queryParameters: const {'limit': '9999'},
        ),
        kGroupId,
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(setup.feed.lastLimit, GetGroupActivityFeed.maxLimit);
    });

    test(
      'a non-integer ?limit= falls back to the default at the reader',
      () async {
        final setup = rootFor();
        seedMember(setup.groups, kMemberUserId);

        final response = await feed_route.onRequest(
          wireContext(
            root: setup.root,
            principal: memberPrincipal(),
            method: HttpMethod.get,
            queryParameters: const {'limit': 'abc'},
          ),
          kGroupId,
        );

        expect(response.statusCode, HttpStatus.ok);
        expect(setup.feed.lastLimit, GetGroupActivityFeed.defaultLimit);
      },
    );

    test('a missing ?limit= falls back to the default at the reader', () async {
      final setup = rootFor();
      seedMember(setup.groups, kMemberUserId);

      final response = await feed_route.onRequest(
        wireContext(
          root: setup.root,
          principal: memberPrincipal(),
          method: HttpMethod.get,
        ),
        kGroupId,
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(setup.feed.lastLimit, GetGroupActivityFeed.defaultLimit);
    });

    test(
      'a non-member is refused 401 group.not_a_member (no oracle)',
      () async {
        final setup = rootFor();

        final response = await feed_route.onRequest(
          wireContext(
            root: setup.root,
            principal: nonMemberPrincipal(),
            method: HttpMethod.get,
          ),
          kGroupId,
        );

        expect(response.statusCode, HttpStatus.unauthorized);
        final body = await decodeBody(response);
        expect(body['code'], 'group.not_a_member');
      },
    );

    test('a transient feed failure is 503 (Tier-3 confined)', () async {
      final setup = rootFor();
      seedMember(setup.groups, kMemberUserId);
      setup.feed.failNextWith(
        const AppError.transient('social.row_corrupt', 'boom'),
      );

      final response = await feed_route.onRequest(
        wireContext(
          root: setup.root,
          principal: memberPrincipal(),
          method: HttpMethod.get,
        ),
        kGroupId,
      );

      expect(response.statusCode, HttpStatus.serviceUnavailable);
    });

    test('feed route rejects a non-GET method with 405', () async {
      final setup = rootFor();

      final response = await feed_route.onRequest(
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
}
