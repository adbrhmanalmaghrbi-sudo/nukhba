import 'dart:io';

import 'package:path/path.dart' as p;

/// The set of internal workspace package names the linter reasons about.
const Set<String> internalPackages = {
  'shared',
  'domain',
  'contracts',
  'application',
  'infrastructure',
  'server',
  'api_client',
  'mobile',
};

/// Clean Architecture dependency rules (Coding Standards ADR, Section 1).
///
/// Maps each layer to the set of *internal* packages it is permitted to import
/// from its own source (`lib/`, plus `routes/` for the server app). A package
/// may always import itself; that is added implicitly.
///
/// The direction of allowed dependencies points strictly inward:
///   server -> {application, infrastructure, contracts, domain, shared}
///   infrastructure -> {application, domain, shared}
///   application -> {domain, shared}
///   contracts -> {shared}
///   domain -> {shared}
///   shared -> {}   (the innermost leaf; depends on nothing internal)
///
/// Client-side boundary (ADR-002 §2.8, ratified for the Flutter App phase —
/// project-context §4, decision #5):
///   api_client -> {contracts, shared}
///     A thin typed HTTP transport that carries the versioned `contracts` DTOs
///     over the wire and reports failures as `shared`'s `Result`/`AppError`. It
///     deliberately never imports `domain`, `application`, `infrastructure`, or
///     `server` — no domain rule, use-case, repository, or route ever leaks to
///     the client; the client only speaks the HTTP contract.
///   mobile -> {api_client, contracts, shared}
///     The Flutter app depends on `api_client` read-only for networking and on
///     `contracts`/`shared` for the DTO shapes and `Result`/`AppError` it
///     renders. It never imports `domain`, `application`, `infrastructure`, or
///     `server` (ADR-002 §2.8: the client consumes only the read-only contract
///     surface + the transport, never a repository implementation or a
///     write-capable use-case).
const Map<String, Set<String>> allowedDependencies = {
  'shared': {},
  'domain': {'shared'},
  'contracts': {'shared'},
  'application': {'domain', 'shared'},
  'infrastructure': {'application', 'domain', 'shared'},
  'server': {'application', 'infrastructure', 'contracts', 'domain', 'shared'},
  'api_client': {'contracts', 'shared'},
  'mobile': {'api_client', 'contracts', 'shared'},
};

/// A single detected rule violation.
final class Violation {
  /// Creates a violation record.
  const Violation({
    required this.file,
    required this.line,
    required this.fromPackage,
    required this.importedPackage,
  });

  /// The offending source file (workspace-relative).
  final String file;

  /// The 1-based line number of the import directive.
  final int line;

  /// The layer whose source contains the illegal import.
  final String fromPackage;

  /// The internal package that must not be imported here.
  final String importedPackage;

  @override
  String toString() =>
      '$file:$line — `$fromPackage` may not import `$importedPackage` '
      '(allowed: ${(allowedDependencies[fromPackage] ?? const <String>{}).join(', ')})';
}

final RegExp _importDirective = RegExp(
  r'''^\s*import\s+['"]package:([a-zA-Z0-9_]+)/''',
);

/// Extracts the internal package imported by [line], or null if the line is
/// not an internal `package:` import.
String? internalImportOf(String line) {
  final match = _importDirective.firstMatch(line);
  if (match == null) return null;
  final pkg = match.group(1)!;
  return internalPackages.contains(pkg) ? pkg : null;
}

/// The source roots to lint for a given [package], relative to [workspaceRoot].
List<String> sourceRootsFor(String package, String workspaceRoot) {
  switch (package) {
    case 'server':
      return [
        p.join(workspaceRoot, 'apps', 'server', 'lib'),
        p.join(workspaceRoot, 'apps', 'server', 'routes'),
      ];
    case 'mobile':
      // The Flutter app lives under apps/, not packages/.
      return [p.join(workspaceRoot, 'apps', 'mobile', 'lib')];
    default:
      return [p.join(workspaceRoot, 'packages', package, 'lib')];
  }
}

/// Lints all internal packages under [workspaceRoot], returning every
/// violation found. Pure and side-effect-free (no printing), so it is directly
/// unit-testable.
List<Violation> lintWorkspace(String workspaceRoot) {
  final violations = <Violation>[];

  for (final entry in allowedDependencies.entries) {
    final package = entry.key;
    final allowed = {...entry.value, package}; // self-import always allowed

    for (final root in sourceRootsFor(package, workspaceRoot)) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;

      final dartFiles = dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'));

      for (final file in dartFiles) {
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final imported = internalImportOf(lines[i]);
          if (imported == null) continue;
          if (allowed.contains(imported)) continue;
          violations.add(
            Violation(
              file: p.relative(file.path, from: workspaceRoot),
              line: i + 1,
              fromPackage: package,
              importedPackage: imported,
            ),
          );
        }
      }
    }
  }

  return violations;
}
