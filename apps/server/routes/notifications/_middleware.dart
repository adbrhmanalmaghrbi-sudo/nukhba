import 'package:dart_frog/dart_frog.dart';
import 'package:server/http/bearer_auth.dart';

/// Guards the whole `/notifications` read/mark subtree with bearer
/// authentication (Security ADR §2), mirroring `/participants`.
///
/// Every notification surface is a **recipient-only self-read/self-mark**
/// (Notifications decision #4): the use-cases (`ListMyNotifications`,
/// `GetUnreadCount`, `MarkNotificationRead`) bind the recipient from the verified
/// principal, never a body or path, and refuse a foreign/unknown id identically
/// as `notification.not_found` (no existence oracle — mirror of the Ledger
/// self-read). There is deliberately NO client route that CREATES a notification
/// (decision #4 — creation is server-triggered only); this subtree exposes only
/// the recipient-facing reads and the one client-safe mutation (mark-read).
Handler middleware(Handler handler) {
  return handler.use(bearerAuth());
}
