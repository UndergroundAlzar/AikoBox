/// The used/total meter a subscription card shows.
///
/// Port of the `Progress` + `calcTraffic` pair in
/// `src/renderer/src/components/profiles/profile-item.tsx`, with the desktop's
/// two date modes shown side by side instead of toggled: a phone has the room
/// for both, and a hidden toggle is a worse trade than one extra line.
library;

import 'package:aikobox_mobile/core/models.dart';
import 'package:aikobox_mobile/l10n/aiko_l10n.dart';
import 'package:aikobox_mobile/theme/app_theme.dart';
import 'package:flutter/material.dart';

import '../data/profile_format.dart';

class SubscriptionUsageBar extends StatelessWidget {
  const SubscriptionUsageBar({
    super.key,
    required this.usage,
    this.foreground,
    this.trackColor,
  });

  final SubscriptionUsage usage;

  /// Text and bar colour. Defaults to `onSurfaceVariant` / `primary`; the
  /// current-profile card passes its own so the meter stays readable on the
  /// selected fill.
  final Color? foreground;
  final Color? trackColor;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final status = AikoStatusColors.of(context);

    final Color text = foreground ?? scheme.onSurfaceVariant;
    final percent = usagePercent(used: usage.used, total: usage.total);
    final fraction = usage.usedFraction;

    // Green until the allowance is mostly gone, amber past 80 %, red past 95 %.
    // Same thresholds the delay chip uses for "fine / worth noticing / bad".
    final Color bar = trackColor ??
        (fraction == null
            ? scheme.primary
            : fraction >= 0.95
            ? status.bad
            : fraction >= 0.8
            ? status.warn
            : status.good);

    final String left = usage.total > 0
        ? l10n.t(
            'profiles.traffic.usage',
            args: <String, Object?>{
              'used': formatTraffic(l10n, usage.used),
              'total': formatTraffic(l10n, usage.total),
            },
          )
        : '${formatTraffic(l10n, usage.used)} · '
              '${l10n.t('profiles.traffic.unlimited')}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                left,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: text),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              _expiryLabel(l10n),
              maxLines: 1,
              style: theme.textTheme.bodySmall?.copyWith(color: text),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            // An unlimited subscription reports no quota; showing a full bar
            // for it would read as "you are out of traffic".
            value: fraction ?? 0,
            minHeight: 4,
            backgroundColor: text.withValues(alpha: 0.20),
            valueColor: AlwaysStoppedAnimation<Color>(bar),
            semanticsLabel: l10n.t('profiles.trafficUsage'),
            semanticsValue: percent == null ? null : '$percent%',
          ),
        ),
      ],
    );
  }

  String _expiryLabel(AikoL10n l10n) {
    final expiresAt = usage.expiresAt;
    if (expiresAt == null) return l10n.t('profiles.neverExpire');
    final days = daysUntil(expiresAt);
    if (days == null || days <= 0) return l10n.t('profiles.traffic.expired');
    return l10n.t(
      'profiles.traffic.remainingDays',
      args: <String, Object?>{'days': days},
    );
  }
}
