/// Snackbars for the profiles screens.
///
/// Every failure in this feature is reported through [showProfileError], which
/// is the single place that turns an exception into text. That is deliberate:
/// a subscription URL is frequently the credential, so there must be exactly
/// one path from "something threw" to "something is on screen", and it has to
/// be the one that redacts (N7).
library;

import 'package:aikobox_mobile/l10n/aiko_l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/profile_error_text.dart';

/// Shows an already-localised message.
void showProfileMessage(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Reports [error]. [fallbackKey] names the sentence to use when the error
/// carries nothing more specific — the caller knows what was being attempted.
void showProfileError(
  BuildContext context,
  Object error, {
  String fallbackKey = 'common.error.default',
}) {
  final l10n = AikoL10n.maybeOf(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (l10n == null || messenger == null) return;

  final described = describeProfileError(
    l10n,
    error,
    fallbackKey: fallbackKey,
  );
  final detail = described.detail;

  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(described.message),
        duration: const Duration(seconds: 6),
        action: detail == null || detail == described.message
            ? null
            : SnackBarAction(
                label: l10n.t('common.details'),
                onPressed: () => _showDetail(context, described.message, detail),
              ),
      ),
    );
}

Future<void> _showDetail(
  BuildContext context,
  String title,
  String detail,
) async {
  final l10n = AikoL10n.maybeOf(context);
  if (l10n == null) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(
        child: SelectableText(
          detail,
          style: Theme.of(
            dialogContext,
          ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: detail));
            if (dialogContext.mounted) Navigator.of(dialogContext).pop();
          },
          child: Text(l10n.t('common.error.copyErrorMessage')),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(l10n.t('common.close')),
        ),
      ],
    ),
  );
}
