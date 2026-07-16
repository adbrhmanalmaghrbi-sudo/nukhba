import 'dart:io';

import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import 'competition_route_harness.dart';
// ignore: always_use_package_imports
import '../../routes/admin/users/[id]/suspend/index.dart' as suspend_route;
// ignore: always_use_package_imports
import '../../routes/admin/users/[id]/reinstate/index.dart' as reinstate_route;
// ignore: always_use_package_imports
import '../../routes/admin/participants/[id]/ledger/index.dart' as ledger_route;
// ignore: always_use_package_imports
import '../../routes/admin/audit/index.dart' as audit_route;

/// Route tests for the Admin Panel surface — the four routes under `/admin`
/// (`POST /admin/users/{id}/suspend`, `POST /admin/users/{id}/reinstate`,
/// `GET /admin/participants/{id}/ledger`, `GET /admin/audit`), exercised through
/// the *real* wiring (`context.read<Future<CompositionRoot>>()` →
/// `root.<useCase>()`) over the in-memory admin repositories from
/// [competition_route_harness]. This covers the edge → use-case → domain → port
/// path end-to-end, hermetically, mirroring `notifications_routes_test.dart` /
/// `social_routes_test.dart` / `ledger_routes_test.dart`.
///
/// It is NOT a substitute for the infrastructure adapters' own tests
/// (infrastructure package) or the use-cases' own tests (application package):
/// its job is the route's status mapping, DTO shaping, path-param/query
/// handling, and that the admin gate — enforced INSIDE each use-case
/// (`Authorization.requireRole(principal, PlatformRole.admin)` → the code
/// `auth.insufficient_role`, verified against `Authorization` on disk, not
/// guessed) — is honoured across the HTTP boundary. Authentication (a verified
/// principal) is provided by `admin/_middleware.dart`'s `bearerAuth()`, so an
/// unauthenticated request never reaches these handlers; that middleware is
/// covered by `bearer_auth_test.dart`, so these tests supply a principal
/// directly and focus on the authorization + behaviour of each route.
void main() {
  // ---------------------------------------------------------------------------
  // POST /admin/users/{id}/suspend — SuspendUser (admin-only command)
  // ---------------------------------------------------------------------------
  group('POST /admin/users/{id}/suspend', () {
    /// Wires suspend + reinstate over a shared in-memory user-admin repo (so a
    /// sanction and its reversal see the same target) and an audit repo (every
    /// sanction records one entry). The clock/id-gen feed the audit recorder.
    ({
      CompositionRoot root,
      InMemoryUserAdminRepository users,
      InMemoryAuditLogRepository audit,
    })
    rootFor({List<User> seededUsers = const []}) {
      final users = InMemoryUserAdminRepository();
      for (final u in seededUsers) {
        users.seed(u);
      }
      final audit = InMemoryAuditLogRepository();
      final recorder = AuditRecorder(
        auditLog: audit,
        idGenerator: ScriptedIdGenerator([kAuditEntryId, kAuditEntryId2]),
        clock: FixedClock(DateTime.utc(2026, 7, 13, 12)),
      );
      final root = CompositionRoot.forTesting(
        suspendUser: SuspendUser(users: users, auditRecorder: recorder),
        reinstateUser: ReinstateUser(users: users, auditRecorder: recorder),
      );
      return (root: root, users: users, audit: audit);
    }

    Future<Response> suspend(
      CompositionRoot root,
      AuthenticatedUser principal,
      String id, {
      Object? body = const {'reason': 'abuse'},
    }) => suspend_route.onRequest(
      wireContext(
        root: root,
        principal: principal,
        method: HttpMethod.post,
        body: body,
      ),
      id,
    );

    test(
      'an admin suspends an active user and gets 200 with suspended status',
      () async {
        final setup = rootFor(seededUsers: [storedUser()]);

        final response = await suspend(
          setup.root,
          adminPrincipal(),
          kTargetUserId,
        );

        expect(response.statusCode, HttpStatus.ok);
        final body = await decodeBody(response);
        expect(body['user_id'], kTargetUserId);
        expect(body['status'], 'suspended');
        // The transition was persisted.
        expect(setup.users.users[kTargetUserId]!.status, UserStatus.suspended);
        // Exactly one immutable audit entry was recorded, correctly attributed.
        expect(setup.audit.entries, hasLength(1));
        final entry = setup.audit.entries.single;
        expect(entry.action, AuditAction.userSuspended);
        expect(entry.actorId.value, kAdminId);
        expect(entry.targetRef, kTargetUserId);
        expect(entry.reason, 'abuse');
        // No points ever leak on the sanction result (Axiom 5).
        expect(body.containsKey('points'), isFalse);
      },
    );

    test('re-suspending an already-suspended user is idempotent (200 '
        'suspended, still one audit per action)', () async {
      final setup = rootFor(
        seededUsers: [storedUser(status: UserStatus.suspended)],
      );

      final response = await suspend(
        setup.root,
        adminPrincipal(),
        kTargetUserId,
      );

      expect(response.statusCode, HttpStatus.ok);
      expect((await decodeBody(response))['status'], 'suspended');
      // The domain transition converges (equal value); still suspended.
      expect(setup.users.users[kTargetUserId]!.status, UserStatus.suspended);
      // The action still records its audit trace (the sanction command ran).
      expect(setup.audit.entries, hasLength(1));
    });

    test('a non-admin caller is rejected 401 auth.insufficient_role — no '
        'sanction, no audit', () async {
      final setup = rootFor(seededUsers: [storedUser()]);

      final response = await suspend(
        setup.root,
        userPrincipal(),
        kTargetUserId,
      );

      expect(response.statusCode, HttpStatus.unauthorized);
      expect((await decodeBody(response))['code'], 'auth.insufficient_role');
      // The user was never touched, no audit trace written (Axiom 2/§2.3).
      expect(setup.users.users[kTargetUserId]!.status, UserStatus.active);
      expect(setup.audit.entries, isEmpty);
    });

    test('a missing reason is rejected 400 before touching state', () async {
      final setup = rootFor(seededUsers: [storedUser()]);

      final response = await suspend(
        setup.root,
        adminPrincipal(),
        kTargetUserId,
        body: const <String, Object?>{},
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect(
        (await decodeBody(response))['code'],
        'admin.sanction_reason_required',
      );
      // No sanction applied, no audit — the reason gate precedes any write.
      expect(setup.users.users[kTargetUserId]!.status, UserStatus.active);
      expect(setup.audit.entries, isEmpty);
    });

    test('a blank reason is rejected 400 before touching state', () async {
      final setup = rootFor(seededUsers: [storedUser()]);

      final response = await suspend(
        setup.root,
        adminPrincipal(),
        kTargetUserId,
        body: const {'reason': '   '},
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect(
        (await decodeBody(response))['code'],
        'admin.sanction_reason_required',
      );
      expect(setup.audit.entries, isEmpty);
    });

    test(
      'suspending an unknown user is rejected 409 admin.user_not_found',
      () async {
        // No user seeded.
        final setup = rootFor();

        final response = await suspend(
          setup.root,
          adminPrincipal(),
          kTargetUserId,
        );

        expect(response.statusCode, HttpStatus.conflict);
        expect((await decodeBody(response))['code'], 'admin.user_not_found');
        expect(setup.audit.entries, isEmpty);
      },
    );

    test('a non-POST method is 405', () async {
      final setup = rootFor(seededUsers: [storedUser()]);

      final response = await suspend_route.onRequest(
        wireContext(
          root: setup.root,
          principal: adminPrincipal(),
          method: HttpMethod.get,
        ),
        kTargetUserId,
      );

      expect(response.statusCode, HttpStatus.methodNotAllowed);
    });
  });

  // ---------------------------------------------------------------------------
  // POST /admin/users/{id}/reinstate — ReinstateUser (admin-only command)
  // ---------------------------------------------------------------------------
  group('POST /admin/users/{id}/reinstate', () {
    ({
      CompositionRoot root,
      InMemoryUserAdminRepository users,
      InMemoryAuditLogRepository audit,
    })
    rootFor({List<User> seededUsers = const []}) {
      final users = InMemoryUserAdminRepository();
      for (final u in seededUsers) {
        users.seed(u);
      }
      final audit = InMemoryAuditLogRepository();
      final recorder = AuditRecorder(
        auditLog: audit,
        idGenerator: ScriptedIdGenerator([kAuditEntryId, kAuditEntryId2]),
        clock: FixedClock(DateTime.utc(2026, 7, 13, 12)),
      );
      final root = CompositionRoot.forTesting(
        suspendUser: SuspendUser(users: users, auditRecorder: recorder),
        reinstateUser: ReinstateUser(users: users, auditRecorder: recorder),
      );
      return (root: root, users: users, audit: audit);
    }

    Future<Response> reinstate(
      CompositionRoot root,
      AuthenticatedUser principal,
      String id, {
      Object? body = const {'reason': 'appeal upheld'},
    }) => reinstate_route.onRequest(
      wireContext(
        root: root,
        principal: principal,
        method: HttpMethod.post,
        body: body,
      ),
      id,
    );

    test(
      'an admin reinstates a suspended user and gets 200 with active status',
      () async {
        final setup = rootFor(
          seededUsers: [storedUser(status: UserStatus.suspended)],
        );

        final response = await reinstate(
          setup.root,
          adminPrincipal(),
          kTargetUserId,
        );

        expect(response.statusCode, HttpStatus.ok);
        final body = await decodeBody(response);
        expect(body['user_id'], kTargetUserId);
        expect(body['status'], 'active');
        expect(setup.users.users[kTargetUserId]!.status, UserStatus.active);
        // One audit entry, recorded as the reinstate action.
        expect(setup.audit.entries, hasLength(1));
        expect(setup.audit.entries.single.action, AuditAction.userReinstated);
        expect(setup.audit.entries.single.reason, 'appeal upheld');
      },
    );

    test(
      'reinstating an already-active user is idempotent (200 active)',
      () async {
        final setup = rootFor(seededUsers: [storedUser()]);

        final response = await reinstate(
          setup.root,
          adminPrincipal(),
          kTargetUserId,
        );

        expect(response.statusCode, HttpStatus.ok);
        expect((await decodeBody(response))['status'], 'active');
        expect(setup.users.users[kTargetUserId]!.status, UserStatus.active);
      },
    );

    test('a non-admin caller is rejected 401 auth.insufficient_role', () async {
      final setup = rootFor(
        seededUsers: [storedUser(status: UserStatus.suspended)],
      );

      final response = await reinstate(
        setup.root,
        userPrincipal(),
        kTargetUserId,
      );

      expect(response.statusCode, HttpStatus.unauthorized);
      expect((await decodeBody(response))['code'], 'auth.insufficient_role');
      // Untouched; still suspended.
      expect(setup.users.users[kTargetUserId]!.status, UserStatus.suspended);
      expect(setup.audit.entries, isEmpty);
    });

    test('a missing reason is rejected 400', () async {
      final setup = rootFor(
        seededUsers: [storedUser(status: UserStatus.suspended)],
      );

      final response = await reinstate(
        setup.root,
        adminPrincipal(),
        kTargetUserId,
        body: const <String, Object?>{},
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect(
        (await decodeBody(response))['code'],
        'admin.sanction_reason_required',
      );
    });

    test('a non-POST method is 405', () async {
      final setup = rootFor();

      final response = await reinstate_route.onRequest(
        wireContext(
          root: setup.root,
          principal: adminPrincipal(),
          method: HttpMethod.get,
        ),
        kTargetUserId,
      );

      expect(response.statusCode, HttpStatus.methodNotAllowed);
    });
  });

  // ---------------------------------------------------------------------------
  // GET /admin/participants/{id}/ledger — ViewParticipantLedger (support read)
  // ---------------------------------------------------------------------------
  group('GET /admin/participants/{id}/ledger', () {
    final participantId =
        (ParticipantId.tryParse(kParticipantId) as Ok<ParticipantId>).value;
    final roundId = (RoundId.tryParse(kRoundId) as Ok<RoundId>).value;
    final at = DateTime.utc(2026, 7, 20, 9, 30);

    Participant participant() => Participant.fromStored(
      id: participantId,
      seasonId: (SeasonId.tryParse(kSeasonId) as Ok<SeasonId>).value,
      userId: (UserId.tryParse(kUserId) as Ok<UserId>).value,
      status: ParticipantStatus.active,
      joinedAt: DateTime.utc(2026, 7, 1),
    );

    PointEntry credit(String entryId, int amount) =>
        (PointEntry.create(
                  id: (PointEntryId.tryParse(entryId) as Ok<PointEntryId>)
                      .value,
                  participantId: participantId,
                  roundId: roundId,
                  kind: EntryKind.roundScore,
                  amount: amount,
                  sourceRef: 'round_score:$kRoundId:$kParticipantId',
                  occurredAt: at,
                )
                as Ok<PointEntry>)
            .value;

    /// Wires the support-read use-case over a participant reader knowing the
    /// canonical participant, a ledger seeded with [entries], and an audit repo
    /// (every support read records one entry). An [auditFailure], when supplied,
    /// scripts the audit append to fail (proves fail-closed).
    Future<
      ({
        CompositionRoot root,
        InMemoryLedgerRepository ledger,
        InMemoryAuditLogRepository audit,
      })
    >
    rootFor({
      List<PointEntry> entries = const [],
      bool knowParticipant = true,
      AppError? auditFailure,
    }) async {
      final ledger = InMemoryLedgerRepository();
      if (entries.isNotEmpty) {
        await ledger.appendEntries(entries);
      }
      final reader = InMemoryParticipantReader();
      if (knowParticipant) {
        reader.add(participant());
      }
      final audit = InMemoryAuditLogRepository();
      if (auditFailure != null) {
        audit.failNextWith(auditFailure);
      }
      final recorder = AuditRecorder(
        auditLog: audit,
        idGenerator: ScriptedIdGenerator([kAuditEntryId]),
        clock: FixedClock(DateTime.utc(2026, 7, 13, 12)),
      );
      final root = CompositionRoot.forTesting(
        viewParticipantLedger: ViewParticipantLedger(
          participantReader: reader,
          ledgerRepository: ledger,
          auditRecorder: recorder,
        ),
      );
      return (root: root, ledger: ledger, audit: audit);
    }

    Future<Response> get(
      CompositionRoot root,
      AuthenticatedUser principal,
      String id, {
      Map<String, String> queryParameters = const {},
    }) => ledger_route.onRequest(
      wireContext(
        root: root,
        principal: principal,
        method: HttpMethod.get,
        queryParameters: queryParameters,
      ),
      id,
    );

    test('an admin reads a participant ledger (200) and one audit entry is '
        'recorded', () async {
      final setup = await rootFor(
        entries: [credit(kAuditEntryId, 4), credit(kAuditEntryId2, 3)],
        // The credits reuse audit-id UUIDs purely as valid entry ids; the
        // participant/round are what matter.
      );

      final response = await get(
        setup.root,
        adminPrincipal(),
        kParticipantId,
        queryParameters: const {'reason': 'support ticket 42'},
      );

      expect(response.statusCode, HttpStatus.ok);
      final body = await decodeBody(response);
      expect(body['participant_id'], kParticipantId);
      final list = body['entries']! as List<Object?>;
      expect(list, hasLength(2));
      // Exactly one support-read audit entry, attributed to the admin, keyed to
      // the participant, carrying the supplied reason (decision OPEN-A #3).
      expect(setup.audit.entries, hasLength(1));
      final entry = setup.audit.entries.single;
      expect(entry.action, AuditAction.participantLedgerViewed);
      expect(entry.actorId.value, kAdminId);
      expect(entry.targetRef, kParticipantId);
      expect(entry.reason, 'support ticket 42');
    });

    test(
      'an empty ledger still serves 200 and still records the audit read',
      () async {
        final setup = await rootFor();

        final response = await get(
          setup.root,
          adminPrincipal(),
          kParticipantId,
        );

        expect(response.statusCode, HttpStatus.ok);
        expect((await decodeBody(response))['entries'], isEmpty);
        // The read is audited regardless of whether the stream has movements.
        expect(setup.audit.entries, hasLength(1));
        // No reason query → the audit entry carries a null reason.
        expect(setup.audit.entries.single.reason, isNull);
      },
    );

    test('a non-admin caller is rejected 401 auth.insufficient_role — no read, '
        'no audit', () async {
      final setup = await rootFor(entries: [credit(kAuditEntryId, 4)]);

      final response = await get(setup.root, userPrincipal(), kParticipantId);

      expect(response.statusCode, HttpStatus.unauthorized);
      expect((await decodeBody(response))['code'], 'auth.insufficient_role');
      // No cross-user data served, no audit trace on the rejected path.
      expect(setup.audit.entries, isEmpty);
    });

    test('an unknown participant is rejected 409 admin.participant_not_found — '
        'no oracle, no audit', () async {
      final setup = await rootFor(knowParticipant: false);

      final response = await get(setup.root, adminPrincipal(), kParticipantId);

      expect(response.statusCode, HttpStatus.conflict);
      expect(
        (await decodeBody(response))['code'],
        'admin.participant_not_found',
      );
      // A missing participant is never audited (nothing was read).
      expect(setup.audit.entries, isEmpty);
    });

    test('a malformed participant id is rejected 400', () async {
      final setup = await rootFor();

      final response = await get(setup.root, adminPrincipal(), 'not-a-uuid');

      expect(response.statusCode, HttpStatus.badRequest);
      expect(setup.audit.entries, isEmpty);
    });

    test('a failed audit write refuses the read (fail-closed) — nothing served '
        'un-traced', () async {
      final setup = await rootFor(
        entries: [credit(kAuditEntryId, 4)],
        auditFailure: const AppError.transient(
          'admin.audit_row_corrupt',
          'boom',
        ),
      );

      final response = await get(setup.root, adminPrincipal(), kParticipantId);

      // The support read is refused (the audit append failed) — the cross-user
      // data is never served without an attributable trace (Security ADR §2.4).
      expect(response.statusCode, HttpStatus.serviceUnavailable);
      // No entry landed on the trail (the append itself failed).
      expect(setup.audit.entries, isEmpty);
    });

    test('a non-GET method is 405', () async {
      final setup = await rootFor();

      final response = await ledger_route.onRequest(
        wireContext(
          root: setup.root,
          principal: adminPrincipal(),
          method: HttpMethod.post,
        ),
        kParticipantId,
      );

      expect(response.statusCode, HttpStatus.methodNotAllowed);
    });
  });

  // ---------------------------------------------------------------------------
  // GET /admin/audit — ListAuditLog (admin-only read of the append-only trail)
  // ---------------------------------------------------------------------------
  group('GET /admin/audit', () {
    ({CompositionRoot root, InMemoryAuditLogRepository audit}) rootFor({
      List<AuditEntry> seeded = const [],
    }) {
      final audit = InMemoryAuditLogRepository();
      for (final e in seeded) {
        audit.seed(e);
      }
      final root = CompositionRoot.forTesting(
        listAuditLog: ListAuditLog(auditLog: audit),
      );
      return (root: root, audit: audit);
    }

    Future<Response> get(
      CompositionRoot root,
      AuthenticatedUser principal, {
      Map<String, String> queryParameters = const {},
    }) => audit_route.onRequest(
      wireContext(
        root: root,
        principal: principal,
        method: HttpMethod.get,
        queryParameters: queryParameters,
      ),
    );

    test('an admin reads the trail newest-first (200)', () async {
      final setup = rootFor(
        seeded: [
          storedAuditEntry(
            id: kAuditEntryId,
            action: AuditAction.userSuspended,
            occurredAt: DateTime.utc(2026, 7, 13, 8),
          ),
          storedAuditEntry(
            id: kAuditEntryId2,
            action: AuditAction.userReinstated,
            occurredAt: DateTime.utc(2026, 7, 13, 10),
          ),
        ],
      );

      final response = await get(setup.root, adminPrincipal());

      expect(response.statusCode, HttpStatus.ok);
      final body = await decodeBody(response);
      final entries = body['entries']! as List<Object?>;
      expect(entries, hasLength(2));
      // Newest-first: the 10:00 reinstate precedes the 08:00 suspend.
      expect((entries.first! as Map)['id'], kAuditEntryId2);
      expect((entries.first! as Map)['action'], 'user_reinstated');
      expect((entries.last! as Map)['id'], kAuditEntryId);
      expect((entries.last! as Map)['action'], 'user_suspended');
      // No points ever leak on an audit row (Axiom 5).
      expect((entries.first! as Map).containsKey('points'), isFalse);
    });

    test('an empty trail is a legitimate empty list (200)', () async {
      final setup = rootFor();

      final response = await get(setup.root, adminPrincipal());

      expect(response.statusCode, HttpStatus.ok);
      expect((await decodeBody(response))['entries'], isEmpty);
    });

    test('a non-admin caller is rejected 401 auth.insufficient_role, even with '
        'rows present', () async {
      final setup = rootFor(seeded: [storedAuditEntry()]);

      final response = await get(setup.root, userPrincipal());

      expect(response.statusCode, HttpStatus.unauthorized);
      expect((await decodeBody(response))['code'], 'auth.insufficient_role');
    });

    test('an in-range ?limit= reaches the repository as-is (clamp)', () async {
      final setup = rootFor();

      final response = await get(
        setup.root,
        adminPrincipal(),
        queryParameters: const {'limit': '10'},
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(setup.audit.lastRequestedLimit, 10);
    });

    test(
      'an over-cap ?limit= is clamped to maxLimit at the repository',
      () async {
        final setup = rootFor();

        final response = await get(
          setup.root,
          adminPrincipal(),
          queryParameters: const {'limit': '9999'},
        );

        expect(response.statusCode, HttpStatus.ok);
        expect(setup.audit.lastRequestedLimit, ListAuditLog.maxLimit);
      },
    );

    test(
      'a non-integer ?limit= falls back to the default at the repository',
      () async {
        final setup = rootFor();

        final response = await get(
          setup.root,
          adminPrincipal(),
          queryParameters: const {'limit': 'abc'},
        );

        expect(response.statusCode, HttpStatus.ok);
        expect(setup.audit.lastRequestedLimit, ListAuditLog.defaultLimit);
      },
    );

    test(
      'a missing ?limit= falls back to the default at the repository',
      () async {
        final setup = rootFor();

        final response = await get(setup.root, adminPrincipal());

        expect(response.statusCode, HttpStatus.ok);
        expect(setup.audit.lastRequestedLimit, ListAuditLog.defaultLimit);
      },
    );

    test('a transient repository failure is 503', () async {
      final setup = rootFor();
      setup.audit.failNextWith(
        const AppError.transient('admin.audit_row_corrupt', 'boom'),
      );

      final response = await get(setup.root, adminPrincipal());

      expect(response.statusCode, HttpStatus.serviceUnavailable);
    });

    test('a non-GET method is 405', () async {
      final setup = rootFor();

      final response = await audit_route.onRequest(
        wireContext(
          root: setup.root,
          principal: adminPrincipal(),
          method: HttpMethod.post,
        ),
      );

      expect(response.statusCode, HttpStatus.methodNotAllowed);
    });
  });
}
