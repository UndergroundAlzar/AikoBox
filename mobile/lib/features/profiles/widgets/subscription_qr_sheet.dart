/// The subscription QR code.
///
/// Port of `src/renderer/src/components/profiles/qr-code-modal.tsx`.
///
/// The code itself has to carry the real URL — copying a subscription to
/// another device is the entire point — but the caption under it does not, so
/// it shows the redacted form and says so. That way holding the phone up to
/// someone does not also show them the token in plain text.
library;

import 'package:aikobox_mobile/l10n/aiko_l10n.dart';
import 'package:aikobox_mobile/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../data/profile_error_text.dart';

/// Shows [url] as a QR code. Returns when the sheet is dismissed.
Future<void> showSubscriptionQrSheet(
  BuildContext context, {
  required String name,
  required String url,
}) => showModalBottomSheet<void>(
  context: context,
  useSafeArea: true,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (sheetContext) => SubscriptionQrSheet(name: name, url: url),
);

class SubscriptionQrSheet extends StatelessWidget {
  const SubscriptionQrSheet({super.key, required this.name, required this.url});

  final String name;
  final String url;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              l10n.t('profiles.qrCode.title'),
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge?.copyWith(
                color: scheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              name,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            Center(
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: ShapeDecoration(
                  // A QR reader needs light modules on a dark background or the
                  // other way round; forcing white here means the code scans in
                  // dark mode too.
                  color: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AikoDims.cardRadius),
                  ),
                ),
                child: QrImageView(
                  data: url,
                  version: QrVersions.auto,
                  size: 220,
                  backgroundColor: Colors.white,
                  errorCorrectionLevel: QrErrorCorrectLevel.M,
                  eyeStyle: const QrEyeStyle(
                    eyeShape: QrEyeShape.square,
                    color: Colors.black,
                  ),
                  dataModuleStyle: const QrDataModuleStyle(
                    dataModuleShape: QrDataModuleShape.square,
                    color: Colors.black,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            SelectableText(
              redactProfileMessage(url),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Icon(
                  Icons.lock_outline_rounded,
                  size: 14,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    l10n.t('profiles.redacted'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            FilledButton.tonalIcon(
              onPressed: () async {
                final messenger = ScaffoldMessenger.maybeOf(context);
                await Clipboard.setData(ClipboardData(text: url));
                messenger?.showSnackBar(
                  SnackBar(content: Text(l10n.t('common.copied'))),
                );
              },
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: Text(l10n.t('common.copy')),
            ),
          ],
        ),
      ),
    );
  }
}
