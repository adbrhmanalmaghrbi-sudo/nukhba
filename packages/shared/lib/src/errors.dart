/// The four closed error classes carried end-to-end (API ADR, Section 5;
/// Coding Standards ADR, Section 4).
///
/// Clients use [ErrorKind] to decide retry behavior: [transient] is
/// retryable; the others are terminal.
enum ErrorKind {
  /// Caller lacks permission for the action.
  authorization,

  /// A business invariant was violated (deadline passed, round locked, etc.).
  invariant,

  /// Input was malformed or failed validation.
  validation,

  /// A transient/infrastructure failure — safe to retry.
  transient,
}

/// A structured application error. Immutable and value-comparable.
final class AppError {
  /// Creates an application error.
  const AppError({
    required this.kind,
    required this.code,
    required this.message,
    this.cause,
  });

  /// Convenience constructor for authorization failures.
  const AppError.authorization(String code, String message)
    : this(kind: ErrorKind.authorization, code: code, message: message);

  /// Convenience constructor for invariant violations.
  const AppError.invariant(String code, String message)
    : this(kind: ErrorKind.invariant, code: code, message: message);

  /// Convenience constructor for validation failures.
  const AppError.validation(String code, String message)
    : this(kind: ErrorKind.validation, code: code, message: message);

  /// Convenience constructor for transient/infrastructure failures.
  const AppError.transient(String code, String message, [Object? cause])
    : this(
        kind: ErrorKind.transient,
        code: code,
        message: message,
        cause: cause,
      );

  /// The error class.
  final ErrorKind kind;

  /// A stable, machine-readable code (e.g. `health.db_unreachable`).
  final String code;

  /// A human-readable description. Never contains secrets.
  final String message;

  /// Optional underlying cause, for server-side logging only.
  final Object? cause;

  /// Whether a client may safely retry the operation that produced this error.
  bool get isRetryable => kind == ErrorKind.transient;

  @override
  bool operator ==(Object other) =>
      other is AppError &&
      other.kind == kind &&
      other.code == code &&
      other.message == message;

  @override
  int get hashCode => Object.hash(kind, code, message);

  @override
  String toString() => cause == null
      ? 'AppError(${kind.name}: $code — $message)'
      : 'AppError(${kind.name}: $code — $message) caused by: $cause';
}
