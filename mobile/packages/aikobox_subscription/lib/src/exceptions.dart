/// Exceptions raised while turning a raw subscription body into a Clash config.
///
/// Both carry a short, already-redacted English `message`. Nothing that reaches
/// these messages may contain subscription content, a URL, a token or a
/// controller secret — see `redact.dart` and non-negotiable N7.
library;

/// The payload is not something we can turn into a Clash config: not YAML, not
/// a Base64 URI list, a declared field with the wrong shape, or a share link
/// whose fields are malformed.
class SubscriptionFormatException implements Exception {
  const SubscriptionFormatException(this.message);

  /// Short, user-safe English description. Never contains payload bytes.
  final String message;

  @override
  String toString() => 'SubscriptionFormatException: $message';
}

/// The payload parses but is larger than the caps in `bounds.dart`.
///
/// Kept distinct from [SubscriptionFormatException] because the caller maps it
/// to a different user-facing outcome ("the subscription is too large") than a
/// parse failure ("the subscription is unusable").
class SubscriptionBoundsException implements Exception {
  const SubscriptionBoundsException(this.message);

  /// Short, user-safe English description. Never contains payload bytes.
  final String message;

  @override
  String toString() => 'SubscriptionBoundsException: $message';
}
