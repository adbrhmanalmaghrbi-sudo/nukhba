import 'package:dart_frog/dart_frog.dart';
import 'package:server/http/bearer_auth.dart';

/// Guards the whole `/fixtures` subtree with bearer authentication (Security
/// ADR §2). Recording a fixture's actual result is admin-only, enforced as the
/// second layer inside the `RecordFixtureResult` use-case.
Handler middleware(Handler handler) {
  return handler.use(bearerAuth());
}
