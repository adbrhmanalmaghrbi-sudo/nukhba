import 'package:api_client/api_client.dart';
import 'package:api_client/src/leaderboards_api.dart';
import 'package:contracts/contracts.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import 'support/mock_transport.dart';

void main() {
  group(
    'LeaderboardsApi.seasonLeaderboard (GET /seasons/{id}/leaderboard)',
    () {
      test('200 -> Ok(SeasonLeaderboardDto) in server order', () async {
        const dto = SeasonLeaderboardDto(
          seasonId: 's-1',
          entries: [
            LeaderboardEntryDto(
              rank: 1,
              participantId: 'p-a',
              totalPoints: 12,
              entryCount: 3,
            ),
            LeaderboardEntryDto(
              rank: 2,
              participantId: 'p-b',
              totalPoints: 7,
              entryCount: 3,
            ),
          ],
        );
        final ctx = buildTransport(
          (_) async => okJson(dto.toJson()),
          token: 'jwt',
        );

        final result = await LeaderboardsApi(
          ctx.transport,
        ).seasonLeaderboard('s-1');

        expect(result, Result<SeasonLeaderboardDto>.ok(dto));
        final req = ctx.captured.single;
        expect(req.method, 'GET');
        expect(req.url.path, '/seasons/s-1/leaderboard');
        expect(req.headers['authorization'], 'Bearer jwt');
      });

      test(
        'a season with no participants -> Ok(empty entries), not an error',
        () async {
          const empty = SeasonLeaderboardDto(seasonId: 's-2', entries: []);
          final ctx = buildTransport((_) async => okJson(empty.toJson()));

          final result = await LeaderboardsApi(
            ctx.transport,
          ).seasonLeaderboard('s-2');

          final value = (result as Ok<SeasonLeaderboardDto>).value;
          expect(value.seasonId, 's-2');
          expect(value.entries, isEmpty);
        },
      );

      test(
        '401 leaderboard.not_a_participant -> Err(authorization) with code',
        () async {
          final ctx = buildTransport(
            (_) async => errorEnvelope(
              401,
              'leaderboard.not_a_participant',
              'Members only.',
            ),
          );

          final result = await LeaderboardsApi(
            ctx.transport,
          ).seasonLeaderboard('s-1');

          final err = (result as Err<SeasonLeaderboardDto>).error;
          expect(err.kind, ErrorKind.authorization);
          expect(err.code, 'leaderboard.not_a_participant');
          expect(err.isRetryable, isFalse);
        },
      );

      test('400 malformed season id -> Err(validation)', () async {
        final ctx = buildTransport(
          (_) async => errorEnvelope(400, 'validation.invalid_id', 'Bad id.'),
        );

        final result = await LeaderboardsApi(
          ctx.transport,
        ).seasonLeaderboard('!!');

        expect(
          (result as Err<SeasonLeaderboardDto>).error.kind,
          ErrorKind.validation,
        );
      });

      test('503 -> Err(transient) retryable', () async {
        final ctx = buildTransport(
          (_) async => errorEnvelope(503, 'transient.upstream', 'Retry.'),
        );

        final result = await LeaderboardsApi(
          ctx.transport,
        ).seasonLeaderboard('s-1');

        expect((result as Err<SeasonLeaderboardDto>).error.isRetryable, isTrue);
      });

      test('network failure -> Err(transient, network_unreachable)', () async {
        final ctx = buildTransport((_) async => throw Exception('dns'));

        final result = await LeaderboardsApi(
          ctx.transport,
        ).seasonLeaderboard('s-1');

        expect(
          (result as Err<SeasonLeaderboardDto>).error.code,
          apiErrorNetworkUnreachable,
        );
      });

      test(
        'a bare 405 (no envelope body) -> synthetic unexpected_status',
        () async {
          final ctx = buildTransport((_) async => bareStatus(405));

          final result = await LeaderboardsApi(
            ctx.transport,
          ).seasonLeaderboard('s-1');

          final err = (result as Err<SeasonLeaderboardDto>).error;
          expect(err.code, apiErrorUnexpectedStatus);
          // 405 < 500 -> classified terminal (validation), not retryable.
          expect(err.kind, ErrorKind.validation);
          expect(err.isRetryable, isFalse);
        },
      );

      test(
        'malformed 200 body -> Err(validation, malformed_response)',
        () async {
          final ctx = buildTransport((_) async => okJson({'season_id': 's-1'}));

          final result = await LeaderboardsApi(
            ctx.transport,
          ).seasonLeaderboard('s-1');

          expect(
            (result as Err<SeasonLeaderboardDto>).error.code,
            apiErrorMalformedResponse,
          );
        },
      );
    },
  );
}
