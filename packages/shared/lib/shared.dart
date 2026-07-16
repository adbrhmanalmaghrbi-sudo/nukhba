/// Dependency-free cross-cutting primitives shared across all layers.
///
/// This package MUST NOT depend on any other package. It is the innermost
/// leaf of the dependency graph (Coding Standards ADR, Section 1).
library;

export 'src/errors.dart';
export 'src/ids.dart';
export 'src/result.dart';
