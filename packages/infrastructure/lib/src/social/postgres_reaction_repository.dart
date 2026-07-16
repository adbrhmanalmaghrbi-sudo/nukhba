import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:infrastructure/src/db/postgres_connection.dart';
// `postgres` exports its own `Result`; we only need its exception hierarchy
// here (to read the SQLSTATE `code`/`constraintName` off a `ServerException`),
// so hide `Result` to keep `Result<T>` unambiguously our `shared` union.
import 'package:postgres/postgres.dart' hide Result;
import 'package:shared/shared.dart';

/// Postgres-backed [ReactionRepository] over the `social.reactions` table
/// (Database ADR; migration `0008_social.sql`).
///
/// Reactions are the ONE new stored Tier-3 surface this phase introduces
/// (Social decision #2). A member has AT MOST ONE live reaction per
/// round-result within a group — uniqueness `(group_id, round_id, user_id)` —
/// so [upsertReaction] is an idempotent `INSERT … ON CONFLICT DO UPDATE`: a
/// first reaction inserts; the same member reacting again (with any emoji)
/// refreshes the existing row in place (never a second row). A genuine racing
/// duplicate that the DB rejects surfaces as [ErrorKind.invariant]
/// `social.reaction_conflict`, which the use-case resolves by re-reading.
///
/// The adapter is *total* (Application ADR §2): it never throws. It speaks only
/// in the domain [Reaction] aggregate and typed ids; SQL and rows never leak. A
/// driver failure is surfaced as [ErrorKind.transient]; a malformed row is
/// mapped to a transient `social.row_corrupt`. All queries bind values through
/// `@named` parameters (Security ADR §2).
///
/// **Tier-3 degradation (decision #4):** a failure here is a typed
/// `Result.err` confined to the Social use-case that called it; it never
/// propagates into a Tier-1 core operation.
final class PostgresReactionRepository implements ReactionRepository {
  /// Creates the repository over an open [PostgresConnection].
  const PostgresReactionRepository(this._connection);

  final PostgresConnection _connection;

  // --------------------------------------------------------------------------
  // upsertReaction — idempotent insert-or-update on the natural key
  // --------------------------------------------------------------------------

  // ON CONFLICT on the natural key updates the emoji + reacted_at in place, so a
  // member swapping their reaction never creates a second row (decision #1/#2).
  // The caller-generated id is used only on the initial insert; a subsequent
  // change keeps the stored id (the update does not touch it). A conflict that
  // is NOT on the natural key (should not happen) still surfaces via the
  // reclassify path as an integrity violation rather than a raw transient.
  static const String _upsertSql = '''
INSERT INTO social.reactions
  (id, group_id, round_id, user_id, emoji, reacted_at)
VALUES
  (@id, @group_id, @round_id, @user_id, @emoji, @reacted_at)
ON CONFLICT ON CONSTRAINT reactions_group_round_user_uniq
DO UPDATE SET emoji = excluded.emoji, reacted_at = excluded.reacted_at
''';

  @override
  Future<Result<void>> upsertReaction(Reaction reaction) async {
    final result = await _connection.query(
      _upsertSql,
      parameters: {
        'id': reaction.id.value,
        'group_id': reaction.groupId.value,
        'round_id': reaction.roundId.value,
        'user_id': reaction.userId.value,
        'emoji': reaction.emoji.wireValue,
        'reacted_at': reaction.reactedAt.toUtc(),
      },
    );
    return switch (result) {
      Err<List<Map<String, dynamic>>>(:final error) => Result.err(
        _reclassify(error),
      ),
      Ok<List<Map<String, dynamic>>>() => const Result.ok(null),
    };
  }

  // --------------------------------------------------------------------------
  // findReaction — the caller's reaction for (group, round, user), or null
  // --------------------------------------------------------------------------

  static const String _findSql = '''
SELECT id, group_id, round_id, user_id, emoji, reacted_at
FROM social.reactions
WHERE group_id = @group_id AND round_id = @round_id AND user_id = @user_id
''';

  @override
  Future<Result<Reaction?>> findReaction(
    GroupId groupId,
    RoundId roundId,
    UserId userId,
  ) async {
    final result = await _connection.query(
      _findSql,
      parameters: {
        'group_id': groupId.value,
        'round_id': roundId.value,
        'user_id': userId.value,
      },
    );
    return switch (result) {
      Err<List<Map<String, dynamic>>>(:final error) => Result.err(error),
      Ok<List<Map<String, dynamic>>>(:final value) =>
        value.isEmpty ? const Result.ok(null) : _mapOne(value.first),
    };
  }

  // --------------------------------------------------------------------------
  // listReactionsForRound — all reactions to (group, round), reactedAt asc
  // --------------------------------------------------------------------------

  static const String _listSql = '''
SELECT id, group_id, round_id, user_id, emoji, reacted_at
FROM social.reactions
WHERE group_id = @group_id AND round_id = @round_id
ORDER BY reacted_at ASC, id ASC
''';

  @override
  Future<Result<List<Reaction>>> listReactionsForRound(
    GroupId groupId,
    RoundId roundId,
  ) async {
    final result = await _connection.query(
      _listSql,
      parameters: {'group_id': groupId.value, 'round_id': roundId.value},
    );
    return switch (result) {
      Err<List<Map<String, dynamic>>>(:final error) => Result.err(error),
      Ok<List<Map<String, dynamic>>>(:final value) => _mapMany(value),
    };
  }

  // --------------------------------------------------------------------------
  // removeReaction — idempotent delete of the caller's own reaction
  // --------------------------------------------------------------------------

  // RETURNING id lets the adapter report whether a row was actually removed
  // (Ok(true)) or there was nothing to remove (Ok(false)) — a retried remove
  // converges (decision #2). The client-write revocation in the migration does
  // NOT apply to the backend service role this adapter runs as.
  static const String _deleteSql = '''
DELETE FROM social.reactions
WHERE group_id = @group_id AND round_id = @round_id AND user_id = @user_id
RETURNING id
''';

  @override
  Future<Result<bool>> removeReaction(
    GroupId groupId,
    RoundId roundId,
    UserId userId,
  ) async {
    final result = await _connection.query(
      _deleteSql,
      parameters: {
        'group_id': groupId.value,
        'round_id': roundId.value,
        'user_id': userId.value,
      },
    );
    return switch (result) {
      Err<List<Map<String, dynamic>>>(:final error) => Result.err(error),
      Ok<List<Map<String, dynamic>>>(:final value) => Result.ok(
        value.isNotEmpty,
      ),
    };
  }

  // --------------------------------------------------------------------------
  // Row mapping
  // --------------------------------------------------------------------------

  Result<List<Reaction>> _mapMany(List<Map<String, dynamic>> rows) {
    final reactions = <Reaction>[];
    for (final row in rows) {
      final mapped = _mapOne(row);
      if (mapped is Err<Reaction?>) {
        return Result.err(mapped.error);
      }
      final reaction = (mapped as Ok<Reaction?>).value;
      // _mapOne only returns Ok(null) on an absent row, which cannot happen
      // when mapping a present result row; guard defensively anyway.
      if (reaction != null) {
        reactions.add(reaction);
      }
    }
    return Result.ok(List<Reaction>.unmodifiable(reactions));
  }

  Result<Reaction?> _mapOne(Map<String, dynamic> row) {
    final idResult = ReactionId.tryParse(row['id']?.toString());
    final groupIdResult = GroupId.tryParse(row['group_id']?.toString());
    final roundIdResult = RoundId.tryParse(row['round_id']?.toString());
    final userIdResult = UserId.tryParse(row['user_id']?.toString());
    final emojiResult = ReactionEmoji.tryParse(row['emoji']?.toString());
    final reactedAt = _readUtcTimestamp(row['reacted_at']);

    if (idResult is Err<ReactionId>) {
      return Result.err(_corrupt('id', idResult.error.message));
    }
    if (groupIdResult is Err<GroupId>) {
      return Result.err(_corrupt('group_id', groupIdResult.error.message));
    }
    if (roundIdResult is Err<RoundId>) {
      return Result.err(_corrupt('round_id', roundIdResult.error.message));
    }
    if (userIdResult is Err<UserId>) {
      return Result.err(_corrupt('user_id', userIdResult.error.message));
    }
    if (emojiResult is Err<ReactionEmoji>) {
      return Result.err(_corrupt('emoji', emojiResult.error.message));
    }
    if (reactedAt == null) {
      return Result.err(_corrupt('reacted_at', 'not a timestamp'));
    }

    // fromStored performs only typing — the row is already trusted storage.
    return Result.ok(
      Reaction.fromStored(
        id: (idResult as Ok<ReactionId>).value,
        groupId: (groupIdResult as Ok<GroupId>).value,
        roundId: (roundIdResult as Ok<RoundId>).value,
        userId: (userIdResult as Ok<UserId>).value,
        emoji: (emojiResult as Ok<ReactionEmoji>).value,
        reactedAt: reactedAt,
      ),
    );
  }

  // --------------------------------------------------------------------------
  // SQLSTATE reclassification (mirror the ledger/group adapters)
  // --------------------------------------------------------------------------

  AppError _reclassify(AppError error) {
    final cause = error.cause;
    if (cause is! ServerException) {
      return error;
    }
    final code = cause.code;
    // 23505 unique_violation (a concurrent duplicate that slipped past
    // ON CONFLICT — the use-case converges on it), 23503 foreign_key_violation
    // (the group, round, or user vanished).
    const integrityCodes = {'23505', '23503'};
    if (code == null || !integrityCodes.contains(code)) {
      return error;
    }
    final constraint = cause.constraintName;
    if (constraint == 'reactions_group_round_user_uniq') {
      // A concurrent reaction by the same member won the race; the upsert
      // use-case re-reads and re-applies, so report the idempotent conflict.
      return const AppError.invariant(
        'social.reaction_conflict',
        'A concurrent reaction won the race',
      );
    }
    if (constraint == 'reactions_group_id_fkey') {
      return const AppError.invariant(
        'social.group_not_found',
        'Group not found',
      );
    }
    if (constraint == 'reactions_round_id_fkey') {
      return const AppError.invariant(
        'social.round_not_found',
        'Round not found',
      );
    }
    if (constraint == 'reactions_user_id_fkey') {
      return const AppError.invariant(
        'social.user_not_found',
        'User not found',
      );
    }
    return const AppError.invariant(
      'social.integrity_violation',
      'The write violated a social integrity rule',
    );
  }

  static DateTime? _readUtcTimestamp(Object? raw) {
    if (raw is DateTime) {
      return raw.toUtc();
    }
    if (raw is String) {
      final parsed = DateTime.tryParse(raw);
      return parsed?.toUtc();
    }
    return null;
  }

  static AppError _corrupt(String field, String detail) => AppError.transient(
    'social.row_corrupt',
    'Stored reactions row has invalid $field: $detail',
  );
}
