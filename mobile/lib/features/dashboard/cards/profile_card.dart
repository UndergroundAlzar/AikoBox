import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../l10n/aiko_l10n.dart';
import '../../../theme/app_theme.dart';
import '../dashboard_card_shell.dart';
import '../dashboard_error.dart';
import '../dashboard_format.dart';
import '../dashboard_navigation.dart';

/// The profile in use: its name, its remaining allowance and when it expires.
///
/// The refresh action re-downloads the subscription. It is an explicit button
/// rather than something that happens on its own (N5) — and because the
/// Android build has no background updater yet, it is the only way a
/// subscription gets refreshed from this screen.
class DashboardProfileCard extends ConsumerStatefulWidget {
  const DashboardProfileCard({super.key, this.status = CardStatus.colSpan2});

  final CardStatus status;

  @override
  ConsumerState<DashboardProfileCard> createState() =>
      _DashboardProfileCardState();
}

class _DashboardProfileCardState extends ConsumerState<DashboardProfileCard> {
  bool _updating = false;

  Future<void> _update(ProfileItem profile) async {
    setState(() => _updating = true);
    try {
      await ref.read(profilesProvider.notifier).updateSubscription(profile.id);
    } catch (error) {
      if (!mounted) return;
      await showDashboardErrorSheet(context, error);
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AikoL10n l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    final AikoStatusColors colors = AikoStatusColors.of(context);
    final ProfileItem? profile = ref.watch(currentProfileProvider);
    final VoidCallback? open = dashboardOpen(
      ref,
      DashboardDestination.profiles,
    );

    if (profile == null) {
      return DashboardCard(
        icon: Icons.folder_off_outlined,
        label: l10n.t('sider.cards.profiles'),
        lines: 1,
        semanticLabel: l10n.t('dashboard.noProfile.title'),
        onTap: open,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              l10n.t('dashboard.noProfile.title'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface,
              ),
            ),
            if (open != null)
              Text(
                l10n.t('dashboard.noProfile.action'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
          ],
        ),
      );
    }

    final SubscriptionUsage? usage = profile.extra;
    final int? percent = usage == null
        ? null
        : usagePercent(used: usage.used, total: usage.total);
    final DateTime? expiresAt = usage?.expiresAt;
    final bool expired =
        expiresAt != null && expiresAt.isBefore(DateTime.now());
    final int? remainingDays = expired ? null : daysUntil(expiresAt);

    return DashboardCard(
      icon: Icons.folder_rounded,
      label: l10n.t('sider.cards.profiles'),
      lines: 2,
      semanticLabel: '${l10n.t('sider.cards.profiles')}: ${profile.name}',
      onTap: open,
      headerActions: <Widget>[
        if (profile.isRemote)
          IconButton(
            onPressed: _updating ? null : () => _update(profile),
            tooltip: l10n.t('common.refresh'),
            icon: _updating
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
          ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            profile.name.isEmpty
                ? l10n.t('sider.cards.emptyProfile')
                : profile.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: <Widget>[
              DashboardCountBadge(
                label: l10n.t(
                  profile.isRemote ? 'sider.cards.remote' : 'sider.cards.local',
                ),
              ),
              const Spacer(),
              if (usage != null)
                Flexible(
                  child: Text(
                    l10n.t(
                      'profiles.traffic.usage',
                      args: <String, Object?>{
                        'used': formatBytes(l10n, usage.used),
                        'total': usage.total > 0
                            ? formatBytes(l10n, usage.total)
                            : l10n.t('profiles.traffic.unlimited'),
                      },
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
          if (percent != null) ...<Widget>[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: percent / 100,
                minHeight: 4,
                backgroundColor: colors.neutralContainer,
                valueColor: AlwaysStoppedAnimation<Color>(
                  expired || percent >= 90
                      ? colors.bad
                      : percent >= 70
                      ? colors.warn
                      : theme.colorScheme.primary,
                ),
              ),
            ),
          ],
          const SizedBox(height: 6),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: Text(
              _trailingLabel(
                l10n,
                profile: profile,
                hasUsage: usage != null,
                expiresAt: expiresAt,
                expired: expired,
                remainingDays: remainingDays,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: expired
                    ? colors.bad
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Expiry when the subscription reports one, otherwise the last update.
  String _trailingLabel(
    AikoL10n l10n, {
    required ProfileItem profile,
    required bool hasUsage,
    required DateTime? expiresAt,
    required bool expired,
    required int? remainingDays,
  }) {
    if (expired) return l10n.t('profiles.traffic.expired');
    if (expiresAt != null) {
      final String date = formatDate(expiresAt);
      if (remainingDays == null) return date;
      return '$date · ${l10n.plural('plural.days', remainingDays)}';
    }
    if (hasUsage) return l10n.t('profiles.neverExpire');
    final DateTime? updatedAt = profile.updatedAt;
    return l10n.t(
      'profiles.traffic.lastUpdate',
      args: <String, Object?>{
        'time': updatedAt == null
            ? l10n.t('common.never')
            : formatDateTime(updatedAt),
      },
    );
  }
}
