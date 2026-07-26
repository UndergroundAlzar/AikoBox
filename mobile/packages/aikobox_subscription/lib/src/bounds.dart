/// Size caps applied to anything that arrives from a subscription server.
///
/// A subscription body is hostile input (N7). These caps are the desktop
/// app's, kept byte-for-byte so a config that imports on Windows imports on
/// Android and a config that is refused on Windows is refused on Android.
///
/// Port of the `MAX_SUBSCRIPTION_*` constants and
/// `assertBoundedClashSubscription` in `src/main/config/subscriptionPayload.ts`.
library;

import 'exceptions.dart';

/// Most `proxies` entries — or share-link lines — a subscription may contain.
const int kMaxSubscriptionProxies = 10000;

/// Most `proxy-providers` entries a subscription may declare.
const int kMaxSubscriptionProviders = 64;

/// Most `proxy-groups` entries a subscription may declare.
const int kMaxSubscriptionGroups = 512;

/// Most `rules` entries a subscription may declare.
const int kMaxSubscriptionRules = 50000;

/// Longest single rule string, or single share-link line, in characters.
const int kMaxSubscriptionLineLength = 16384;

/// Reads [value] as a string-keyed map, mirroring the desktop's `asDict`:
/// anything that is not a map (including a list) reads as empty.
Map<String, dynamic> asClashDict(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, item) => MapEntry(key.toString(), item));
  }
  return const <String, dynamic>{};
}

/// Reads [value] as a list, mirroring the desktop's `Array.isArray` guards.
List<dynamic> asClashList(Object? value) =>
    value is List ? value : const <dynamic>[];

/// Throws [SubscriptionBoundsException] when [clash] exceeds any cap.
///
/// Safe to call more than once on the same config; it never mutates.
void assertBoundedClashSubscription(Map<String, dynamic> clash) {
  final proxies = asClashList(clash['proxies']);
  final providers = asClashDict(clash['proxy-providers']);
  final groups = asClashList(clash['proxy-groups']);
  final rules = asClashList(clash['rules']);

  if (proxies.length > kMaxSubscriptionProxies) {
    throw const SubscriptionBoundsException(
      'Subscription exceeds $kMaxSubscriptionProxies proxy nodes',
    );
  }
  if (providers.length > kMaxSubscriptionProviders) {
    throw const SubscriptionBoundsException(
      'Subscription exceeds $kMaxSubscriptionProviders proxy providers',
    );
  }
  if (groups.length > kMaxSubscriptionGroups) {
    throw const SubscriptionBoundsException(
      'Subscription exceeds $kMaxSubscriptionGroups proxy groups',
    );
  }
  if (rules.length > kMaxSubscriptionRules) {
    throw const SubscriptionBoundsException(
      'Subscription exceeds $kMaxSubscriptionRules rules',
    );
  }
  for (final rule in rules) {
    if (rule is String && rule.length > kMaxSubscriptionLineLength) {
      throw const SubscriptionBoundsException(
        'Subscription rule exceeds $kMaxSubscriptionLineLength characters',
      );
    }
  }
}
