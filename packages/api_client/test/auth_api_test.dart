import 'package:api_client/api_client.dart';
import 'package:api_client/src/auth_api.dart';
import 'package:contracts/contracts.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import 'support/mock_transport.dart';

void main() {
  group('AuthApi.me', () {
    test(
      '200 -> Ok(MeResponseDto), sends GET /me with bearer + accept',
      () async {
        const expected = MeResponseDto(
          user: AuthenticatedUserDto(
            userId: 'u-1',
            role: 'user',
            status: 'active',
            email: 'a@example.com',
          ),
        );
        final ctx = buildTransport(
          (_) async => okJson(expected.toJson()),
          token: 'jwt-abc',
        );

        final result = await AuthApi(ctx.transport).me();

        expect(result, Result<MeResponseDto>.ok(expected));
        final req = ctx.captured.single;
        expect(req.method, 'GET');
        expect(req.url.path, '/me');
        expect(req.headers['authorization'], 'Bearer jwt-abc');
        expect(req.headers['accept'], 'application/json');
      },
    );

    test(
      'omits Authorization header when the token provider yields null',
      () async {
        const body = MeResponseDto(
          user: AuthenticatedUserDto(
            userId: 'u',
            role: 'user',
            status: 'active',
          ),
        );
        final ctx = buildTransport(
          (_) async => okJson(body.toJson()),
          token: null,
        );

        await AuthApi(ctx.transport).me();

        expect(
          ctx.captured.single.headers.containsKey('authorization'),
          isFalse,
        );
      },
    );

    test('401 -> Err(authorization) with the server code/message', () async {
      final ctx = buildTransport(
        (_) async => errorEnvelope(401, 'auth.token_expired', 'Token expired.'),
      );

      final result = await AuthApi(ctx.transport).me();

      final err = (result as Err<MeResponseDto>).error;
      expect(err.kind, ErrorKind.authorization);
      expect(err.code, 'auth.token_expired');
      expect(err.message, 'Token expired.');
      expect(err.isRetryable, isFalse);
    });

    test('503 -> Err(transient), retryable', () async {
      final ctx = buildTransport(
        (_) async => errorEnvelope(503, 'health.db_unreachable', 'Down.'),
      );

      final result = await AuthApi(ctx.transport).me();

      final err = (result as Err<MeResponseDto>).error;
      expect(err.kind, ErrorKind.transient);
      expect(err.isRetryable, isTrue);
    });

    test('network failure -> Err(transient, network_unreachable)', () async {
      final ctx = buildTransport((_) async => throw Exception('socket reset'));

      final result = await AuthApi(ctx.transport).me();

      final err = (result as Err<MeResponseDto>).error;
      expect(err.kind, ErrorKind.transient);
      expect(err.code, apiErrorNetworkUnreachable);
      expect(err.isRetryable, isTrue);
    });

    test('malformed 200 body -> Err(validation, malformed_response)', () async {
      final ctx = buildTransport((_) async => okJson({'unexpected': 'shape'}));

      final result = await AuthApi(ctx.transport).me();

      final err = (result as Err<MeResponseDto>).error;
      expect(err.kind, ErrorKind.validation);
      expect(err.code, apiErrorMalformedResponse);
    });

    test(
      '200 body that is a JSON array (not object) -> malformed_response',
      () async {
        final ctx = buildTransport((_) async => okJson(<Object>[]));

        final result = await AuthApi(ctx.transport).me();

        expect(
          (result as Err<MeResponseDto>).error.code,
          apiErrorMalformedResponse,
        );
      },
    );
  });
}
