import 'dart:math';

import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// [InviteCodeGenerator] backed by the Dart SDK's cryptographically-strong
/// [Random.secure] — no external package (§3 version log: Groups introduces no
/// new dependency).
///
/// Draws exactly `InviteCode.codeLength` characters from `InviteCode.alphabet`
/// (the closed, URL-safe, visually-unambiguous alphabet the domain owns), so the
/// produced code always passes `InviteCode.tryParse`. Using `Random.secure`
/// makes a live code unpredictable, which is what the invite-only, no-existence-
/// oracle design relies on (decision #3): possession of the code is the
/// capability, so it must not be guessable.
///
/// Total by construction: the alphabet is non-empty and the length is positive,
/// so `tryParse` on the drawn string cannot fail; the defensive fallback below
/// never executes in practice but keeps the method non-throwing (Application ADR
/// §2 — a port implementation must not throw).
final class UuidInviteCodeGenerator implements InviteCodeGenerator {
  /// Creates a generator over a cryptographically-strong RNG.
  UuidInviteCodeGenerator() : _random = Random.secure();

  final Random _random;

  @override
  InviteCode newCode() {
    final alphabet = InviteCode.alphabet;
    final buffer = StringBuffer();
    for (var i = 0; i < InviteCode.codeLength; i++) {
      buffer.write(alphabet[_random.nextInt(alphabet.length)]);
    }
    final parsed = InviteCode.tryParse(buffer.toString());
    if (parsed is Ok<InviteCode>) {
      return parsed.value;
    }
    // Unreachable: the draw is always in-alphabet and exactly codeLength long.
    // Kept non-throwing as a defence-in-depth backstop by re-drawing a single
    // deterministic in-alphabet code (never observed in practice).
    final fallback = alphabet.substring(0, 1) * InviteCode.codeLength;
    return (InviteCode.tryParse(fallback) as Ok<InviteCode>).value;
  }
}
