import 'package:application/application.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import 'fakes.dart';

const _owner = 'aaaaaaaa-0000-0000-0000-000000000001';
const _member = 'bbbbbbbb-0000-0000-0000-000000000002';
const _outsider = 'cccccccc-0000-0000-0000-000000000003';
const _groupId = '11111111-1111-1111-1111-111111111111';
const _season = '99999999-9999-9999-9999-999999999999';

const _pA = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
const _pB = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
const _pC = 'cccccccc-cccc-cccc-cccc-cccccccccccc';

({
  GetGroupLeaderboard useCase,
  InMemoryGroupRepository repo,
  InMemoryGroupStandingsReader reader,
})
_harness() {
  final repo = InMemoryGroupRepository()
    ..seedGroup(storedGroup(id: _groupId, ownerId: _owner))
    ..seedMembership(
      storedMembership(
        id: '22222222-2222-2222-2222-222222222222',
        groupId: _groupId,
        userId: _owner,
        role: GroupRole.owner,
      ),
    )
    ..seedMembership(
      storedMembership(
        id: '33333333-3333-3333-3333-333333333333',
        groupId: _groupId,
        userId: _member,
      ),
    );
  final reader = InMemoryGroupStandingsReader();
  final useCase = GetGroupLeaderboard(
    repository: repo,
    standingsReader: reader,
  );
  return (useCase: useCase, repo: repo, reader: reader);
}

void main() {
  group('GetGroupLeaderboard — member-only + ranking', () {
    test(
      'a member reads the ranked group board (points desc, "1224" ties)',
      () async {
        final h = _harness();
        h.reader.seed(_groupId, _season, [
          standing(
            userId: _member,
            participantId: _pA,
            totalPoints: 10,
            joinedAt: DateTime.utc(2026, 7, 1),
          ),
          standing(
            userId: _owner,
            participantId: _pB,
            totalPoints: 10,
            joinedAt: DateTime.utc(2026, 7, 2),
          ),
          standing(userId: _outsider, participantId: _pC, totalPoints: 4),
        ]);
        final board =
            (await h.useCase.call(
                      principal: principalUser(userId: _member),
                      groupId: _groupId,
                      seasonId: _season,
                    )
                    as Ok<GroupLeaderboard>)
                .value;
        expect(board.groupId.value, _groupId);
        expect(board.seasonId.value, _season);
        // Ranks: pA & pB tied at 10 → both rank 1, pC rank 3.
        expect(board.standings.map((s) => s.entry.rank).toList(), [1, 1, 3]);
        // Display order pA (earlier join) then pB then pC.
        expect(
          board.standings.map((s) => s.entry.participantId.value).toList(),
          [_pA, _pB, _pC],
        );
        // Each ranked entry re-keyed to its member userId.
        expect(board.standings.map((s) => s.userId.value).toList(), [
          _member,
          _owner,
          _outsider,
        ]);
      },
    );

    test('an empty group board is legitimate (not an error)', () async {
      final h = _harness();
      h.reader.seed(_groupId, _season, const []);
      final board =
          (await h.useCase.call(
                    principal: principalUser(userId: _member),
                    groupId: _groupId,
                    seasonId: _season,
                  )
                  as Ok<GroupLeaderboard>)
              .value;
      expect(board.standings, isEmpty);
    });

    test(
      'a non-member is refused group.not_a_member (no existence oracle)',
      () async {
        final h = _harness();
        final result = await h.useCase.call(
          principal: principalUser(userId: _outsider),
          groupId: _groupId,
          seasonId: _season,
        );
        final error = (result as Err<GroupLeaderboard>).error;
        expect(error.code, 'group.not_a_member');
        expect(error.kind, ErrorKind.authorization);
      },
    );

    test('a malformed group id is a validation error', () async {
      final h = _harness();
      final result = await h.useCase.call(
        principal: principalUser(userId: _member),
        groupId: 'not-a-uuid',
        seasonId: _season,
      );
      expect(
        (result as Err<GroupLeaderboard>).error.kind,
        ErrorKind.validation,
      );
    });

    test('a malformed season id is a validation error', () async {
      final h = _harness();
      final result = await h.useCase.call(
        principal: principalUser(userId: _member),
        groupId: _groupId,
        seasonId: 'not-a-uuid',
      );
      expect(
        (result as Err<GroupLeaderboard>).error.kind,
        ErrorKind.validation,
      );
    });

    test('propagates a transient standings-read failure', () async {
      final h = _harness();
      h.reader.failNextWith(const AppError.transient('db.down', 'x'));
      final result = await h.useCase.call(
        principal: principalUser(userId: _member),
        groupId: _groupId,
        seasonId: _season,
      );
      expect((result as Err<GroupLeaderboard>).error.kind, ErrorKind.transient);
    });
  });
}
