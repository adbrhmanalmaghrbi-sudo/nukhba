/// The client-side home of the Supabase access token.
///
/// `api_client` is deliberately token-agnostic (its [TokenProvider] just asks
/// "what is the current bearer token?"); the app owns *where* that token lives.
/// This is the seam: a small async key-value contract for the one credential
/// the client holds, with a platform-secure implementation and an in-memory
/// fake for tests.
///
/// It stores/loads only the opaque token string — it never verifies, decodes,
/// or refreshes it (that is the identity provider's concern; the server
/// verifies every token per Security ADR §2).
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A minimal async store for the single bearer credential.
///
/// Every method is total in the sense that it completes with a value or throws
/// only on a genuine platform-storage failure; callers treat a thrown read as
/// "no token" (see [SecureTokenStore.read]).
abstract interface class TokenStore {
  /// Returns the persisted access token, or `null` if none is stored.
  Future<String?> read();

  /// Persists [token] as the current access token, replacing any previous one.
  Future<void> write(String token);

  /// Removes any persisted token (sign-out).
  Future<void> clear();
}

/// Platform-secure [TokenStore] backed by `flutter_secure_storage`
/// (Keychain on iOS, Keystore/EncryptedSharedPreferences on Android, a
/// WebCrypto-backed store on web).
final class SecureTokenStore implements TokenStore {
  /// Creates a secure store over [storage].
  const SecureTokenStore(this._storage);

  final FlutterSecureStorage _storage;

  /// The storage key under which the access token is persisted.
  static const String tokenKey = 'nukhba.access_token';

  @override
  Future<String?> read() async {
    // A read failure (e.g. a corrupted keystore entry) is treated as "no
    // token" rather than crashing the app on boot — the user is simply asked
    // to sign in again. The failure is not swallowed silently in higher
    // layers: an absent token routes to the sign-in screen.
    try {
      return await _storage.read(key: tokenKey);
    } on Object {
      return null;
    }
  }

  @override
  Future<void> write(String token) {
    return _storage.write(key: tokenKey, value: token);
  }

  @override
  Future<void> clear() {
    return _storage.delete(key: tokenKey);
  }
}

/// An in-memory [TokenStore] for tests and for a transient web session where
/// no persistence is desired. Not used by the production wiring.
final class InMemoryTokenStore implements TokenStore {
  /// Creates an in-memory store, optionally seeded with an existing [token].
  InMemoryTokenStore([this._token]);

  String? _token;

  @override
  Future<String?> read() async => _token;

  @override
  Future<void> write(String token) async => _token = token;

  @override
  Future<void> clear() async => _token = null;
}
