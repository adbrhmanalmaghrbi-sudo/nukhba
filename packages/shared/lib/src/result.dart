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
  bool operator ==(Object other) => other is Ok<T> && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

/// Failed [Result].
final class Err<T> extends Result<T> {
  /// Creates a failure carrying [error].
  const Err(this.error);

  /// The failure detail.
  final AppError error;

  @override
  bool operator ==(Object other) => other is Err<T> && other.error == error;

  @override
  int get hashCode => error.hashCode;
}
