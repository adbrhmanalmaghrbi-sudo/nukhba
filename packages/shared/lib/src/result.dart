import 'package:shared/src/errors.dart';

/// A typed success-or-failure result.
///
/// Used for control flow across layer boundaries instead of throwing
/// (Coding Standards ADR, Section 4). Exhaustive `switch` over the sealed
/// hierarchy is enforced by the analyzer.
sealed class Result<T> {
  const Result();

  /// Creates a successful result.
  const factory Result.ok(T value) = Ok<T>;

  /// Creates a failed result.
  const factory Result.err(AppError error) = Err<T>;

  /// Whether this result represents success.
  bool get isOk => this is Ok<T>;

  /// Whether this result represents failure.
  bool get isErr => this is Err<T>;

  /// Transforms the success value, preserving failures.
  Result<R> map<R>(R Function(T value) transform) => switch (this) {
    Ok<T>(:final value) => Result<R>.ok(transform(value)),
    Err<T>(:final error) => Result<R>.err(error),
  };

  /// Returns the success value or the result of [orElse] on failure.
  T getOrElse(T Function(AppError error) orElse) => switch (this) {
    Ok<T>(:final value) => value,
    Err<T>(:final error) => orElse(error),
  };
}

/// Successful [Result].
final class Ok<T> extends Result<T> {
  /// Creates a success carrying [value].
  const Ok(this.value);

  /// The success value.
  final T value;

  @override
  bool operator ==(Object other) =>
      other is Ok<T> && _deepEquals(other.value, value);

  @override
  int get hashCode => _deepHashCode(value);
}

/// Failed [Result].
final class Err<T> extends Result<T> {
  /// Creates a failure carrying [error].
  const Err(this.error);

  /// The failure detail.
  final AppError error;

  @override
  bool operator ==(Object other) =>
      other is Err<T> && _deepEquals(other.error, error);

  @override
  int get hashCode => _deepHashCode(error);
}

/// Structural equality for [a] and [b], recursing into [List], [Map], and
/// [Set] so that value-holders like [Ok] and [Err] compare by content rather
/// than by reference. Falls back to the object's own `==` for everything
/// else (DTOs, primitives, enums).
bool _deepEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Set && b is Set) {
    if (a.length != b.length) return false;
    return a.every((e) => b.any((o) => _deepEquals(e, o)));
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !_deepEquals(a[key], b[key])) return false;
    }
    return true;
  }
  return a == b;
}

/// Structural hash code counterpart to [_deepEquals].
int _deepHashCode(Object? value) {
  if (value is List) {
    return Object.hashAll(value.map(_deepHashCode));
  }
  if (value is Set) {
    return value.fold(0, (acc, e) => acc ^ _deepHashCode(e));
  }
  if (value is Map) {
    return value.entries.fold(
      0,
      (acc, e) => acc ^ Object.hash(e.key, _deepHashCode(e.value)),
    );
  }
  return value.hashCode;
}
