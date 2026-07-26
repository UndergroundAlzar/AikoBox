/// Per-profile subscription credentials.
///
/// `ProfileItem` deliberately does not carry the `Authorization` header value:
/// the profile index is a plain YAML file in app storage, and a bearer token is
/// not something to leave lying in it. But a subscription that needs a token to
/// download needs it again on every refresh, so it has to be kept somewhere.
///
/// It goes in the Android keystore via `flutter_secure_storage`, keyed by
/// profile id. Two consequences worth knowing:
///
///  * The token never appears in a backup of `profile.yaml`, and never in a log
///    line or an error message — the error paths in this feature run every
///    string through the subscription redaction helper.
///  * Deleting a profile deletes its token; nothing else does.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Reads and writes subscription credentials.
class ProfileSecretStore {
  /// The default `AndroidOptions` are the right ones as of
  /// `flutter_secure_storage` 10.3: `encryptedSharedPreferences` is deprecated
  /// there because Jetpack Security is deprecated upstream, and the plugin now
  /// migrates existing data to its own ciphers on first access.
  ProfileSecretStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const String _prefix = 'aikobox.profile.authToken.';

  final FlutterSecureStorage _storage;

  /// The stored `Authorization` value for [id], or null.
  ///
  /// A keystore that refuses to answer (a device mid-upgrade, a user who just
  /// changed their lock screen) is reported as "no token" rather than as a
  /// failure: the refresh then fails with the server's own 401, which is a far
  /// more actionable message than a keystore error.
  Future<String?> readAuthToken(String id) async {
    try {
      final value = await _storage.read(key: '$_prefix$id');
      return (value == null || value.isEmpty) ? null : value;
    } catch (_) {
      return null;
    }
  }

  /// Stores, or with a null/empty [token] removes, the credential for [id].
  Future<void> writeAuthToken(String id, String? token) async {
    final key = '$_prefix$id';
    try {
      if (token == null || token.isEmpty) {
        await _storage.delete(key: key);
      } else {
        await _storage.write(key: key, value: token);
      }
    } catch (_) {
      // Losing the token means the next refresh asks for it again. That is a
      // far better outcome than refusing to import the subscription at all.
    }
  }

  Future<void> forget(String id) => writeAuthToken(id, null);
}
