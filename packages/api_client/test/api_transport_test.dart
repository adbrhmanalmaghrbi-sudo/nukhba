import 'package:api_client/api_client.dart';
import 'package:api_client/src/api_error.dart';
import 'package:contracts/contracts.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import 'support/mock_transport.dart';

void main() {
  group('ApiTransport path resolution', () {
    test('preserves a reverse-proxy mount prefix on the base URI', () async {
      const dto = CompetitionDto(
        id: 'c',
        name: 'N',
        format: 'football_scoreline',
        visibility: 'public',
      );
      // Base has a mount path ('/api/'); a server-relative '/competitions/c'
      // must join UNDER it, not replace it.
      final ctx = buildTransport(
        (_) async => okJson(dto.toJson()),
        baseUri: Uri.parse('https://host.example/api/'),
      );

      await ctx.transport.getObject<CompetitionDto>(
        '/competitions/c',
        parse: CompetitionDto.fromJson,
      );

      expect(
        ctx.captured.single.url.toString(),
        'https://host.example/api/competitions/c',
      );
    });

    test('merges query parameters into the resolved URI', () async {
      final ctx = buildTransport((_) async => okJson(<Object>[]));

      await ctx.transport.getList<CompetitionDto>(
        '/competitions',
        query: const {'visibility': 'public'},
        parseElement: CompetitionDto.fromJson,
      );

      expect(ctx.captured.single.url.queryParameters, {'visibility': 'public'});
    });
  });

  group('decodeError classification (inverse of error_envelope.dart)', () {
    test('kindForStatus maps the contract statuses', () {
      expect(kindForStatus(400), ErrorKind.validation);
      expect(kindForStatus(401), ErrorKind.authorization);
      expect(kindForStatus(403), ErrorKind.authorization); // defensive
      expect(kindForStatus(404), ErrorKind.invariant);
      expect(kindForStatus(409), ErrorKind.invariant);
      expect(kindForStatus(503), ErrorKind.transient);
      expect(kindForStatus(418), isNull); // unmodelled
    });

    test(
      'valid envelope under an unmodelled 5xx -> transient, code preserved',
      () {
        final err = decodeError(
          502,
          '{"schema_version":1,"code":"proxy.bad_gateway","message":"Nope."}',
        );
        expect(err.kind, ErrorKind.transient);
        expect(err.code, 'proxy.bad_gateway');
      },
    );

    test(
      'valid envelope under an unmodelled 4xx -> invariant, code preserved',
      () {
        final err = decodeError(
          451,
          '{"schema_version":1,"code":"legal.unavailable","message":"No."}',
        );
        expect(err.kind, ErrorKind.invariant);
        expect(err.code, 'legal.unavailable');
      },
    );

    test('no body under 5xx -> synthetic transient unexpected_status', () {
      final err = decodeError(500, '');
      expect(err.kind, ErrorKind.transient);
      expect(err.code, apiErrorUnexpectedStatus);
      expect(err.isRetryable, isTrue);
    });

    test('non-envelope JSON object is not mistaken for an error envelope', () {
      // Has neither `code` nor `message` as strings -> falls through to
      // synthetic-from-status.
      final err = decodeError(400, '{"foo":123}');
      expect(err.code, apiErrorUnexpectedStatus);
      expect(err.kind, ErrorKind.validation);
    });
  });

  group('helper constructors', () {
    test('networkError is transient + retryable and keeps the cause', () {
      final cause = Exception('boom');
      final err = networkError(cause);
      expect(err.kind, ErrorKind.transient);
      expect(err.code, apiErrorNetworkUnreachable);
      expect(err.isRetryable, isTrue);
      expect(err.cause, same(cause));
    });

    test('malformedResponse is terminal validation', () {
      final err = malformedResponse('bad shape');
      expect(err.kind, ErrorKind.validation);
      expect(err.code, apiErrorMalformedResponse);
      expect(err.isRetryable, isFalse);
    });
  });
}
