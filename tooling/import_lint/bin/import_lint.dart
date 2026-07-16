import 'dart:io';

import 'package:import_lint/import_lint.dart';

/// CLI entry point invoked by `melos run import-lint` from the workspace root.
///
/// Enforces the Clean Architecture dependency rules (Coding Standards ADR,
/// Section 1). Exits non-zero — failing CI — if any layer imports a package it
/// is forbidden to depend on.
void main(List<String> args) {
  final workspaceRoot = args.isNotEmpty ? args.first : Directory.current.path;

  final violations = lintWorkspace(workspaceRoot);

  if (violations.isEmpty) {
    stdout.writeln('import-lint: OK — no architecture violations found.');
    return;
  }

  stderr.writeln('import-lint: ${violations.length} violation(s) found:');
  for (final v in violations) {
    stderr.writeln('  - $v');
  }
  exitCode = 1;
}
