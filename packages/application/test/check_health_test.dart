import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

/// In-memory fake of the port (Coding Standards ADR, Section 6: use-cases are
/// tested against in-memory fakes, no infrastructure).
final class _FakeHealthRepository implements HealthRepository {
  _FakeHealthRepository(this._response);
  final Result<bool> _response;

  @override
  Future<Result<bool>> pingDatabase() async => _response;
}

void main() {
  group('CheckHealth', () {
    test('reports healthy when DB ping is Ok(true)', () async {
      final useCase = CheckHealth(_FakeHealthRepository(const Result.ok(true)));
      final result = await useCase();
      expect(result.isOk, isTrue);
      expect((result as Ok<HealthCheck>).value.status, HealthStatus.healthy);
    });

    test('reports unhealthy when DB ping is Ok(false)', () async {
      final useCase = CheckHealth(
        _FakeHealthRepository(const Result.ok(false)),
      );
      final result = await useCase();
      expect((result as Ok<HealthCheck>).value.status, HealthStatus.unhealthy);
    });

    test('degrades gracefully to unhealthy on transient DB error', () async {
      final useCase = CheckHealth(
        _FakeHealthRepository(
          const Result.err(AppError.transient('db', 'unreachable')),
        ),
      );
      final result = await useCase();
      expect(result.isOk, isTrue);
      expect((result as Ok<HealthCheck>).value.status, HealthStatus.unhealthy);
    });
  });
}
