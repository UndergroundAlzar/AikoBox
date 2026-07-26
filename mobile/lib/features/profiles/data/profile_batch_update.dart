/// "Update all" — sequential refresh with the active profile deferred to last.
///
/// Port of `src/renderer/src/utils/profile-batch-update.ts`. Three properties
/// are load-bearing and are the reason this is a separate, tested function
/// rather than a `Future.wait` in the page:
///
///  1. **Sequential.** A phone on a hotel Wi-Fi hitting eight subscription
///     servers at once mostly produces eight timeouts.
///  2. **The current profile goes last.** A successful update of the profile
///     the core is running restarts it; doing that in the middle would abort
///     the remaining downloads along with the tunnel.
///  3. **One failure never stops the others.** Every failure is caught,
///     classified, and reported at the end.
library;

import 'package:aikobox_mobile/core/models.dart';

/// Why one profile in a batch failed. Stable values so the UI can map them to
/// l10n keys instead of matching on message text.
enum ProfileBatchFailureKind {
  authentication,
  backoff,
  invalidContent,
  network,
  notFound,
  unknown,
}

/// One failed profile.
class ProfileBatchFailure {
  const ProfileBatchFailure({
    required this.id,
    required this.name,
    required this.kind,
  });

  final String id;

  /// The profile's display name, or its id when it has none.
  final String name;
  final ProfileBatchFailureKind kind;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProfileBatchFailure &&
          other.id == id &&
          other.name == name &&
          other.kind == kind;

  @override
  int get hashCode => Object.hash(id, name, kind);

  @override
  String toString() => 'ProfileBatchFailure($id, ${kind.name})';
}

/// The outcome of one "update all" run.
class ProfileBatchResult {
  const ProfileBatchResult({
    required this.total,
    required this.succeeded,
    required this.failed,
    required this.failures,
  });

  static const ProfileBatchResult empty = ProfileBatchResult(
    total: 0,
    succeeded: 0,
    failed: 0,
    failures: <ProfileBatchFailure>[],
  );

  /// How many profiles were eligible — local profiles are not counted.
  final int total;
  final int succeeded;
  final int failed;
  final List<ProfileBatchFailure> failures;

  bool get isEmpty => total == 0;
  bool get allSucceeded => total > 0 && failed == 0;
  bool get allFailed => total > 0 && succeeded == 0;
  bool get isPartial => succeeded > 0 && failed > 0;

  @override
  String toString() =>
      'ProfileBatchResult($succeeded/$total ok, $failed failed)';
}

/// Buckets an error into a [ProfileBatchFailureKind].
///
/// Matching on message text is inherited from the desktop and is deliberately
/// kept: the errors come from several layers (HTTP, YAML, the core) and there
/// is no single typed hierarchy to switch on. `SubscriptionException` carries a
/// code, but by the time it reaches here it may have been wrapped.
///
/// The message is only ever *read* here; it is never surfaced. Anything shown
/// to the user goes through the redaction helper first.
ProfileBatchFailureKind classifyProfileFailure(Object error) {
  final message = error.toString().toLowerCase();

  if (_authentication.hasMatch(message)) {
    return ProfileBatchFailureKind.authentication;
  }
  if (_notFound.hasMatch(message)) return ProfileBatchFailureKind.notFound;
  if (message.contains('backoff')) return ProfileBatchFailureKind.backoff;
  if (_network.hasMatch(message)) return ProfileBatchFailureKind.network;
  if (_invalidContent.hasMatch(message)) {
    return ProfileBatchFailureKind.invalidContent;
  }
  return ProfileBatchFailureKind.unknown;
}

final RegExp _authentication = RegExp(
  r'\b(401|403|unauthori[sz]ed|forbidden|authentication|'
  r'redirectcrossoriginwithcredentials)\b',
);
final RegExp _notFound = RegExp(r'\b(404|not found|notfound)\b');
final RegExp _network = RegExp(
  r'\b(network|timeout|timed out|econnrefused|enotfound|fetch failed|'
  r'socketexception|handshakeexception|connection closed|'
  r'toomanyredirects|redirectdowngrade)\b',
);
final RegExp _invalidContent = RegExp(
  r'\b(yaml|parse|syntax|invalid content|html response|htmlresponse|'
  r'unusablecontent|outofbounds|emptyresponse|toolarge)\b',
);

/// True when [item] is something "update all" can refresh.
///
/// The desktop also updates `plugin` profiles; the `.cpx` plugin gateway is
/// Windows-only and is not ported, so only subscriptions qualify.
bool isBatchUpdatable(ProfileItem item) =>
    item.isRemote && (item.url?.trim().isNotEmpty ?? false);

/// Refreshes every updatable profile in [items], one at a time.
///
/// [update] is called once per profile and may throw; a throw is recorded and
/// the run continues. [onProgress] receives the profile about to be refreshed
/// and its 0-based position, so the page can say which one is in flight.
Future<ProfileBatchResult> runProfileBatchUpdate(
  List<ProfileItem> items,
  String? currentId,
  Future<void> Function(ProfileItem item) update, {
  void Function(ProfileItem item, int index, int total)? onProgress,
}) async {
  final targets = items.where(isBatchUpdatable).toList(growable: false);
  final ordered = <ProfileItem>[
    ...targets.where((item) => item.id != currentId),
    ...targets.where((item) => item.id == currentId),
  ];

  final failures = <ProfileBatchFailure>[];
  for (var index = 0; index < ordered.length; index++) {
    final item = ordered[index];
    onProgress?.call(item, index, ordered.length);
    try {
      await update(item);
    } catch (error) {
      failures.add(
        ProfileBatchFailure(
          id: item.id,
          name: item.name.trim().isEmpty ? item.id : item.name,
          kind: classifyProfileFailure(error),
        ),
      );
    }
  }

  return ProfileBatchResult(
    total: ordered.length,
    succeeded: ordered.length - failures.length,
    failed: failures.length,
    failures: List<ProfileBatchFailure>.unmodifiable(failures),
  );
}
