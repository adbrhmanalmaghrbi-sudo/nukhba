import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

void main() {
  group('ReactionKind', () {
    test('closed set is exactly the six v1 kinds', () {
      expect(ReactionKind.values, [
        ReactionKind.like,
        ReactionKind.fire,
        ReactionKind.clap,
        ReactionKind.laugh,
        ReactionKind.sad,
        ReactionKind.shock,
      ]);
    });

    test('wireValue tokens are stable', () {
      expect(ReactionKind.like.wireValue, 'like');
      expect(ReactionKind.fire.wireValue, 'fire');
      expect(ReactionKind.clap.wireValue, 'clap');
      expect(ReactionKind.laugh.wireValue, 'laugh');
      expect(ReactionKind.sad.wireValue, 'sad');
      expect(ReactionKind.shock.wireValue, 'shock');
    });
  });

  group('ReactionEmoji', () {
    test('tryParse round-trips every wire token', () {
      for (final kind in ReactionKind.values) {
        final parsed = ReactionEmoji.tryParse(kind.wireValue);
        expect((parsed as Ok<ReactionEmoji>).value.kind, kind);
        expect(parsed.value.wireValue, kind.wireValue);
      }
    });

    test(
      'tryParse rejects an unknown/null token as validation (no free text)',
      () {
        final unknown = ReactionEmoji.tryParse('rocket');
        expect(
          (unknown as Err<ReactionEmoji>).error.kind,
          ErrorKind.validation,
        );
        expect(unknown.error.code, 'social.reaction_emoji_unknown');
        expect(
          (ReactionEmoji.tryParse(null) as Err<ReactionEmoji>).error.code,
          'social.reaction_emoji_unknown',
        );
        // An arbitrary emoji glyph is NOT accepted — only the closed token set.
        expect(
          (ReactionEmoji.tryParse('🚀') as Err<ReactionEmoji>).error.code,
          'social.reaction_emoji_unknown',
        );
      },
    );

    test('value-comparable by kind', () {
      const a = ReactionEmoji.of(ReactionKind.fire);
      const b = ReactionEmoji.of(ReactionKind.fire);
      const c = ReactionEmoji.of(ReactionKind.clap);
      expect(a, b);
      expect(a == c, isFalse);
    });
  });
}
