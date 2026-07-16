import 'package:application/src/common/id_generator.dart';
import 'package:application/src/competition/ports/competition_repository.dart';
import 'package:application/src/identity/authorization.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Use-case: create a new [Competition] (Application ADR, Section 2: a command,
/// speaking a domain intent — `CreateCompetition`, not a raw insert).
///
/// Authorization is the first layer: only a platform [PlatformRole.admin] (or a
/// `service` principal, which is a superset) may create a competition
/// (Next-Task brief: "admin-only for create/open-round"). The second layer —
/// business invariants — is enforced by the domain (`Competition.create`
/// validates the name/format/visibility) and by the repository/schema (id
/// uniqueness).
///
/// Idempotency/retry-safety (Application ADR, Section 2): the id is generated
/// server-side once per invocation; a genuine duplicate-id collision from the
/// generator is astronomically unlikely and, if it ever occurred, is surfaced
/// as an [ErrorKind.invariant] by the repository rather than silently
/// overwriting.
///
/// Never throws; returns a typed [Result] whose [ErrorKind] the edge maps to an
/// HTTP status.
final class CreateCompetition {
  /// Creates the use-case over its collaborators.
  const CreateCompetition({
    required CompetitionRepository repository,
    required IdGenerator idGenerator,
  }) : _repository = repository,
       _idGenerator = idGenerator;

  final CompetitionRepository _repository;
  final IdGenerator _idGenerator;

  /// Creates a competition owned/administered by [principal].
  ///
  /// [name] is untrusted display text; [format] and [visibility] are untrusted
  /// tokens parsed into closed domain enums. Any parse/validation failure short-
  /// circuits with [ErrorKind.validation]; insufficient authority with
  /// [ErrorKind.authorization].
  Future<Result<Competition>> call({
    required AuthenticatedUser principal,
    required String name,
    required String format,
    required String visibility,
  }) async {
    final auth = Authorization.requireRole(principal, PlatformRole.admin);
    if (auth is Err<AuthenticatedUser>) {
      return Result.err(auth.error);
    }

    final formatResult = FormatType.tryParse(format);
    if (formatResult is Err<FormatType>) {
      return Result.err(formatResult.error);
    }

    final visibilityResult = CompetitionVisibility.tryParse(visibility);
    if (visibilityResult is Err<CompetitionVisibility>) {
      return Result.err(visibilityResult.error);
    }

    final idResult = CompetitionId.tryParse(_idGenerator.newUuid());
    if (idResult is Err<CompetitionId>) {
      return Result.err(idResult.error);
    }

    final competitionResult = Competition.create(
      id: (idResult as Ok<CompetitionId>).value,
      name: name,
      format: (formatResult as Ok<FormatType>).value,
      visibility: (visibilityResult as Ok<CompetitionVisibility>).value,
    );
    if (competitionResult is Err<Competition>) {
      return Result.err(competitionResult.error);
    }
    final competition = (competitionResult as Ok<Competition>).value;

    final saved = await _repository.saveCompetition(competition);
    return switch (saved) {
      Ok<void>() => Result.ok(competition),
      Err<void>(:final error) => Result.err(error),
    };
  }
}
