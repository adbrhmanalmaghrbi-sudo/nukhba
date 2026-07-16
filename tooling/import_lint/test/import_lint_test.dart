import 'dart:io';

import 'package:import_lint/import_lint.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('internalImportOf', () {
    test('recognises an internal package import', () {
      expect(
        internalImportOf("import 'package:domain/domain.dart';"),
        'domain',
      );
    });

    test('ignores third-party and dart: imports', () {
      expect(internalImportOf("import 'dart:io';"), isNull);
      expect(
        internalImportOf("import 'package:dart_frog/dart_frog.dart';"),
        isNull,
      );
    });

    test('ignores relative imports', () {
      expect(internalImportOf("import '../routes/health.dart';"), isNull);
    });
  });

  group('lintWorkspace', () {
    late Directory tempRoot;

    setUp(() => tempRoot = Directory.systemTemp.createTempSync('import_lint'));
    tearDown(() => tempRoot.deleteSync(recursive: true));

    void writeSource(String packageDir, String fileName, String contents) {
      final dir = Directory(p.join(tempRoot.path, packageDir))
        ..createSync(recursive: true);
      File(p.join(dir.path, fileName)).writeAsStringSync(contents);
    }

    test('passes when dependencies point strictly inward', () {
      writeSource(
        'packages/application/lib',
        'ok.dart',
        "import 'package:domain/domain.dart';\n"
            "import 'package:shared/shared.dart';\n",
      );
      expect(lintWorkspace(tempRoot.path), isEmpty);
    });

    test('flags application importing infrastructure (outward dependency)', () {
      writeSource(
        'packages/application/lib',
        'bad.dart',
        "import 'package:infrastructure/infrastructure.dart';\n",
      );

      final violations = lintWorkspace(tempRoot.path);

      expect(violations, hasLength(1));
      expect(violations.single.fromPackage, 'application');
      expect(violations.single.importedPackage, 'infrastructure');
      expect(violations.single.line, 1);
    });

    test('flags shared importing any internal package', () {
      writeSource(
        'packages/shared/lib',
        'bad.dart',
        "import 'package:domain/domain.dart';\n",
      );

      final violations = lintWorkspace(tempRoot.path);
      expect(violations.single.fromPackage, 'shared');
      expect(violations.single.importedPackage, 'domain');
    });

    test('allows the server layer to import every inner package', () {
      writeSource(
        'apps/server/routes',
        'health.dart',
        "import 'package:application/application.dart';\n"
            "import 'package:infrastructure/infrastructure.dart';\n"
            "import 'package:contracts/contracts.dart';\n"
            "import 'package:domain/domain.dart';\n"
            "import 'package:shared/shared.dart';\n",
      );
      expect(lintWorkspace(tempRoot.path), isEmpty);
    });

    test('allows api_client to import only contracts + shared', () {
      writeSource(
        'packages/api_client/lib',
        'ok.dart',
        "import 'package:contracts/contracts.dart';\n"
            "import 'package:shared/shared.dart';\n",
      );
      expect(lintWorkspace(tempRoot.path), isEmpty);
    });

    test('flags api_client importing application (outward/forbidden)', () {
      writeSource(
        'packages/api_client/lib',
        'bad.dart',
        "import 'package:application/application.dart';\n",
      );

      final violations = lintWorkspace(tempRoot.path);
      expect(violations.single.fromPackage, 'api_client');
      expect(violations.single.importedPackage, 'application');
    });

    test('flags api_client importing domain (forbidden)', () {
      writeSource(
        'packages/api_client/lib',
        'bad.dart',
        "import 'package:domain/domain.dart';\n",
      );

      final violations = lintWorkspace(tempRoot.path);
      expect(violations.single.fromPackage, 'api_client');
      expect(violations.single.importedPackage, 'domain');
    });

    test('allows mobile to import api_client + contracts + shared', () {
      writeSource(
        'apps/mobile/lib',
        'ok.dart',
        "import 'package:api_client/api_client.dart';\n"
            "import 'package:contracts/contracts.dart';\n"
            "import 'package:shared/shared.dart';\n",
      );
      expect(lintWorkspace(tempRoot.path), isEmpty);
    });

    test('flags mobile importing infrastructure (forbidden)', () {
      writeSource(
        'apps/mobile/lib',
        'bad.dart',
        "import 'package:infrastructure/infrastructure.dart';\n",
      );

      final violations = lintWorkspace(tempRoot.path);
      expect(violations.single.fromPackage, 'mobile');
      expect(violations.single.importedPackage, 'infrastructure');
    });

    test('flags mobile importing server or application (forbidden)', () {
      writeSource(
        'apps/mobile/lib',
        'bad.dart',
        "import 'package:server/composition/composition_root.dart';\n"
            "import 'package:application/application.dart';\n",
      );

      final violations = lintWorkspace(tempRoot.path);
      expect(violations, hasLength(2));
      expect(violations.map((v) => v.importedPackage).toSet(), {
        'server',
        'application',
      });
      expect(violations.every((v) => v.fromPackage == 'mobile'), isTrue);
    });
  });

  group('internalImportOf recognises the client-side packages', () {
    test('api_client is internal', () {
      expect(
        internalImportOf("import 'package:api_client/api_client.dart';"),
        'api_client',
      );
    });

    test('mobile is internal', () {
      expect(internalImportOf("import 'package:mobile/main.dart';"), 'mobile');
    });
  });
}
