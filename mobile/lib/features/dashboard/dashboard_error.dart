/// Turning a thrown core failure into something a person can read.
///
/// Every failure the core layer raises carries a stable code
/// ([CoreStartException.code], [AikoCoreException.code],
/// [SubscriptionErrorCode]). This file maps codes to l10n keys and, crucially,
/// keeps the core's and the converter's own lines **verbatim** in the details
/// block — N4 makes those messages load-bearing, so they are shown as data,
/// not paraphrased into a friendlier sentence.
library;

import 'package:aikobox_subscription/aikobox_subscription.dart'
    show redactSecrets;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/providers.dart';
import '../../l10n/aiko_l10n.dart';
import '../../theme/app_theme.dart';

/// A failure, resolved into display strings.
@immutable
class DashboardErrorPresentation {
  const DashboardErrorPresentation({
    required this.title,
    this.message,
    this.details = const <String>[],
  });

  /// Localised heading.
  final String title;

  /// Localised explanation, when one exists for this code.
  final String? message;

  /// The core's / converter's own output, unmodified.
  final List<String> details;

  /// Everything worth putting on the clipboard.
  String get clipboardText => <String>[title, ?message, ...details].join('\n');
}

String? _localisedCodeTitle(AikoL10n l10n, String code) {
  switch (code) {
    case CoreStartException.codeNoProfile:
      return l10n.t('dashboard.noProfile.title');
    case CoreStartException.codeProfileUnreadable:
      return l10n.t('error.code.E_PROFILE_NOT_FOUND');
    case CoreStartException.codeVpnPermissionDenied:
      return l10n.t('vpn.permission.denied.title');
    case CoreStartException.codeConversionRefused:
      return l10n.t('mihomo.error.profileCheckFailed');
  }
  final String key = 'error.code.$code';
  return l10n.has(key) ? l10n.t(key) : null;
}

String? _localisedCodeMessage(AikoL10n l10n, String code) {
  switch (code) {
    case CoreStartException.codeVpnPermissionDenied:
      return l10n.t('vpn.permission.denied.message');
    case CoreStartException.codeHealthGateFailed:
      return l10n.t('vpn.healthCheck.failed');
    case CoreStartException.codeNoProfile:
      return l10n.t('profiles.empty.description');
  }
  return null;
}

/// Maps [error] onto display strings. Never throws, and never invents detail
/// that the error did not carry.
DashboardErrorPresentation dashboardErrorPresentation(
  AikoL10n l10n,
  Object error,
) {
  if (error is CoreStartException) {
    return DashboardErrorPresentation(
      title:
          _localisedCodeTitle(l10n, error.code) ??
          l10n.t('common.error.default'),
      message: _localisedCodeMessage(l10n, error.code) ?? error.message,
      details: error.details,
    );
  }
  if (error is AikoCoreException) {
    return DashboardErrorPresentation(
      title:
          _localisedCodeTitle(l10n, error.code) ??
          l10n.t('common.error.default'),
      message: _localisedCodeMessage(l10n, error.code) ?? error.message,
      details: <String>[if (error.details != null) error.details!],
    );
  }
  if (error is SubscriptionException) {
    return DashboardErrorPresentation(
      title: l10n.t('error.code.E_SUBSCRIPTION_FETCH_FAILED'),
      message: error.message,
    );
  }
  if (error is ClashApiException) {
    return DashboardErrorPresentation(
      title: l10n.t('dashboard.core.notRunning'),
      message: error.message,
    );
  }
  return DashboardErrorPresentation(
    title: l10n.t('common.error.default'),
    // The untyped fallback is the one branch that can be handed an arbitrary
    // exception, so it is the one branch that has to assume the string is
    // hostile (N7). The typed branches above are left alone deliberately: their
    // messages are either already redacted by the core layer or are the
    // converter's own refusals, which N4 requires verbatim.
    message: redactSecrets(error.toString()),
  );
}

/// Shows [error] as a modal sheet, with the raw core output kept verbatim and
/// copyable.
///
/// [actionLabel] / [onAction] add one call-to-action button — "Import a
/// subscription" when the start failed because nothing is selected, say.
Future<void> showDashboardErrorSheet(
  BuildContext context,
  Object error, {
  String? actionLabel,
  VoidCallback? onAction,
}) {
  final AikoL10n l10n = AikoL10n.of(context);
  final DashboardErrorPresentation presentation = dashboardErrorPresentation(
    l10n,
    error,
  );

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (BuildContext sheetContext) => _ErrorSheet(
      presentation: presentation,
      actionLabel: actionLabel,
      onAction: onAction == null
          ? null
          : () {
              Navigator.of(sheetContext).pop();
              onAction();
            },
    ),
  );
}

class _ErrorSheet extends StatelessWidget {
  const _ErrorSheet({
    required this.presentation,
    this.actionLabel,
    this.onAction,
  });

  final DashboardErrorPresentation presentation;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AikoL10n l10n = AikoL10n.of(context);

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Center(
              child: Container(
                width: 56,
                height: 56,
                decoration: ShapeDecoration(
                  color: scheme.errorContainer,
                  shape: const CircleBorder(),
                ),
                child: Icon(
                  Icons.error_outline_rounded,
                  size: 28,
                  color: scheme.error,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              presentation.title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge?.copyWith(
                color: scheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (presentation.message != null) ...<Widget>[
              const SizedBox(height: 10),
              Text(
                presentation.message!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            if (presentation.details.isNotEmpty) ...<Widget>[
              const SizedBox(height: 16),
              Container(
                constraints: const BoxConstraints(maxHeight: 180),
                padding: const EdgeInsets.all(12),
                decoration: ShapeDecoration(
                  color: scheme.surfaceContainerHighest,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AikoDims.cardRadius),
                  ),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    presentation.details.join('\n'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontFamily: 'monospace',
                      fontFamilyFallback: const <String>['monospace'],
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 20),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(text: presentation.clipboardText),
                      );
                      if (!context.mounted) return;
                      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                        SnackBar(content: Text(l10n.t('common.copied'))),
                      );
                    },
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    label: Text(
                      l10n.t('common.copy'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed:
                        onAction ?? () => Navigator.of(context).maybePop(),
                    child: Text(
                      actionLabel ?? l10n.t('common.close'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
