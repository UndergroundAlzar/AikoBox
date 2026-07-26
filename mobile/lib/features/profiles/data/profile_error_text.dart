/// Turning a failure into something safe to put on screen.
///
/// **N7.** A subscription URL routinely *is* the credential — `?token=…`,
/// `https://user:pass@host/sub`. Nothing in this feature shows an error message
/// without it passing through [redactProfileMessage] first, and that includes
/// messages produced by layers below this one: `http`'s exceptions carry the
/// request URI, and a hand-written override can put anything in a parse error.
///
/// The user-facing sentence always comes from `l10n`; the redacted technical
/// text is only ever offered as an expandable detail.
library;

import 'package:aikobox_mobile/core/core_channel.dart';
import 'package:aikobox_mobile/core/core_controller.dart';
import 'package:aikobox_mobile/core/profile_store.dart';
import 'package:aikobox_mobile/l10n/aiko_l10n.dart';
import 'package:aikobox_subscription/aikobox_subscription.dart' show redactUrl;

import 'profile_batch_update.dart';
import 'yaml_document.dart';

/// A failure, ready for a snackbar.
class ProfileErrorText {
  const ProfileErrorText({required this.message, this.detail});

  /// Localised, safe to display.
  final String message;

  /// Redacted technical text, or null when there is nothing extra to say.
  final String? detail;

  @override
  String toString() => detail == null ? message : '$message ($detail)';
}

/// Anything that looks like an absolute URL, so it can be handed to
/// [redactUrl]. Deliberately greedy about what counts as a URL — a false
/// positive costs a redacted word, a false negative leaks a token.
final RegExp _urlLike = RegExp(
  r'[a-zA-Z][a-zA-Z0-9+.-]*://[^\s<>"' r"'" r']+',
);

/// Replaces every URL in [text] with its redacted form.
String redactProfileMessage(String text) =>
    text.replaceAllMapped(_urlLike, (match) {
      try {
        return redactUrl(match.group(0)!);
      } catch (_) {
        // A URL the redactor itself cannot parse must not be shown raw.
        return '[redacted]';
      }
    });

/// Maps [error] onto a localised sentence plus a redacted detail line.
///
/// [fallbackKey] is the sentence used when nothing more specific fits — the
/// caller knows what the user was trying to do, this function does not.
ProfileErrorText describeProfileError(
  AikoL10n l10n,
  Object error, {
  String fallbackKey = 'common.error.default',
}) {
  final detail = redactProfileMessage(_rawMessage(error));

  if (error is SubscriptionException) {
    return ProfileErrorText(
      message: l10n.t(_subscriptionKey(error.code)),
      detail: detail,
    );
  }

  if (error is CoreStartException) {
    final key = 'error.code.${error.code}';
    return ProfileErrorText(
      message: l10n.has(key) ? l10n.t(key) : l10n.t(fallbackKey),
      detail: error.details.isEmpty
          ? detail
          : redactProfileMessage(error.details.join('\n')),
    );
  }

  if (error is AikoCoreException) {
    final key = 'error.code.${error.code}';
    return ProfileErrorText(
      message: l10n.has(key) ? l10n.t(key) : l10n.t(fallbackKey),
      detail: detail,
    );
  }

  if (error is YamlDocumentException) {
    return ProfileErrorText(
      message: l10n.t('error.code.E_SUBSCRIPTION_INVALID'),
      detail: error.hasPosition
          ? '${error.line}:${error.column} ${redactProfileMessage(error.message)}'
          : detail,
    );
  }

  return ProfileErrorText(message: l10n.t(fallbackKey), detail: detail);
}

/// The sentence for one profile that failed inside "update all".
String describeBatchFailure(AikoL10n l10n, ProfileBatchFailure failure) {
  final reason = switch (failure.kind) {
    ProfileBatchFailureKind.authentication => l10n.t(
      'error.code.E_SUBSCRIPTION_FETCH_FAILED',
    ),
    ProfileBatchFailureKind.notFound => l10n.t(
      'error.code.E_PROFILE_NOT_FOUND',
    ),
    ProfileBatchFailureKind.network || ProfileBatchFailureKind.backoff => l10n
        .t('error.code.E_SUBSCRIPTION_FETCH_FAILED'),
    ProfileBatchFailureKind.invalidContent => l10n.t(
      'error.code.E_SUBSCRIPTION_INVALID',
    ),
    ProfileBatchFailureKind.unknown => l10n.t('error.code.E_UNKNOWN'),
  };
  return '${redactProfileMessage(failure.name)} — $reason';
}

String _subscriptionKey(SubscriptionErrorCode code) => switch (code) {
  SubscriptionErrorCode.invalidUrl ||
  SubscriptionErrorCode.notHttps ||
  SubscriptionErrorCode.redirectDowngrade ||
  SubscriptionErrorCode.redirectCrossOriginWithCredentials ||
  SubscriptionErrorCode.tooManyRedirects ||
  SubscriptionErrorCode.httpStatus ||
  SubscriptionErrorCode.timeout ||
  SubscriptionErrorCode.network ||
  SubscriptionErrorCode.notModifiedWithoutCache =>
    'error.code.E_SUBSCRIPTION_FETCH_FAILED',
  SubscriptionErrorCode.tooLarge ||
  SubscriptionErrorCode.htmlResponse ||
  SubscriptionErrorCode.emptyResponse ||
  SubscriptionErrorCode.unusableContent ||
  SubscriptionErrorCode.outOfBounds =>
    'error.code.E_SUBSCRIPTION_INVALID',
};

String _rawMessage(Object error) => switch (error) {
  SubscriptionException(:final message) => message,
  CoreStartException(:final message) => message,
  AikoCoreException(:final message) => message,
  YamlDocumentException(:final message) => message,
  FormatException(:final message) => message,
  _ => error.toString(),
};
