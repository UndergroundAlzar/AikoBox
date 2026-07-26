/// One profile in the list.
///
/// Port of `src/renderer/src/components/profiles/profile-item.tsx`. The desktop
/// puts its actions behind a right-click menu and a hover-only refresh button;
/// on a phone the refresh button is always visible and the menu is a long-press
/// or an explicit overflow button, because neither hover nor right-click
/// exists.
///
/// Presentational on purpose: no providers, no navigation, no `l10n` beyond
/// reading the labels it draws. Everything that changes state is a callback,
/// which is what makes this the one part of the feature that can be widget
/// tested before the config packages land.
library;

import 'package:aikobox_mobile/core/models.dart';
import 'package:aikobox_mobile/l10n/aiko_l10n.dart';
import 'package:aikobox_mobile/theme/app_theme.dart';
import 'package:aikobox_mobile/widgets/widgets.dart';
import 'package:flutter/material.dart';

import '../data/profile_format.dart';
import 'subscription_usage_bar.dart';

/// Everything the overflow menu can do to a profile.
enum ProfileCardAction {
  refresh,
  editInfo,
  editFile,
  editRules,
  editOverride,
  showQrCode,
  openHome,
  delete,
}

class ProfileCard extends StatelessWidget {
  const ProfileCard({
    super.key,
    required this.item,
    required this.isCurrent,
    required this.onSelect,
    required this.onAction,
    this.isRefreshing = false,
    this.isBusy = false,
    this.hasOverride = false,
    this.dragHandle,
  });

  final ProfileItem item;

  /// Draws the card in the selected state and disables "use this profile".
  final bool isCurrent;

  /// This card's own subscription is being downloaded.
  final bool isRefreshing;

  /// Something else is in flight — an import, or an "update all". Every action
  /// is disabled so two writers can never race for the same profile file.
  final bool isBusy;

  /// The profile carries an override document; shown as a chip so a config
  /// that does not match the subscription is never a surprise.
  final bool hasOverride;

  /// A `ReorderableDragStartListener` supplied by the list.
  final Widget? dragHandle;

  final VoidCallback onSelect;
  final void Function(ProfileCardAction action) onAction;

  bool get _canRefresh =>
      item.isRemote && (item.url?.trim().isNotEmpty ?? false);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final Color foreground = isCurrent
        ? scheme.onPrimaryContainer
        : scheme.onSurface;
    final Color secondary = isCurrent
        ? scheme.onPrimaryContainer.withValues(alpha: 0.75)
        : scheme.onSurfaceVariant;

    final usage = item.extra;

    return Opacity(
      opacity: isBusy && !isRefreshing ? 0.6 : 1,
      child: CommonCard(
        isSelected: isCurrent,
        onTap: isBusy || isCurrent ? null : onSelect,
        onLongPress: isBusy ? null : () => _openMenu(context),
        semanticLabel: item.name,
        padding: const EdgeInsets.fromLTRB(
          AikoDims.cardPadding,
          12,
          6,
          AikoDims.cardPadding,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                if (dragHandle != null) ...<Widget>[
                  IconTheme.merge(
                    data: IconThemeData(color: secondary, size: 20),
                    child: dragHandle!,
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: foreground,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (_canRefresh)
                  IconButton(
                    onPressed: isBusy
                        ? null
                        : () => onAction(ProfileCardAction.refresh),
                    tooltip: l10n.t('common.refresh'),
                    visualDensity: VisualDensity.compact,
                    color: secondary,
                    icon: isRefreshing
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: secondary,
                            ),
                          )
                        : const Icon(Icons.refresh_rounded, size: 20),
                  ),
                IconButton(
                  onPressed: isBusy ? null : () => _openMenu(context),
                  tooltip: l10n.t('common.more'),
                  visualDensity: VisualDensity.compact,
                  color: secondary,
                  icon: const Icon(Icons.more_vert_rounded, size: 20),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  _Tag(
                    label: l10n.t(
                      item.isRemote ? 'profiles.remote' : 'profiles.local',
                    ),
                    foreground: isCurrent ? scheme.onPrimaryContainer : null,
                  ),
                  if (isCurrent)
                    _Tag(
                      label: l10n.t('profiles.current'),
                      foreground: scheme.onPrimaryContainer,
                      filled: true,
                    ),
                  if (hasOverride)
                    _Tag(
                      label: l10n.t('profiles.editFile.override'),
                      foreground: isCurrent ? scheme.onPrimaryContainer : null,
                    ),
                  if (item.autoUpdate)
                    _Tag(
                      label: l10n.t('profiles.editInfo.autoUpdate'),
                      foreground: isCurrent ? scheme.onPrimaryContainer : null,
                    ),
                ],
              ),
            ),
            if (usage != null) ...<Widget>[
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: SubscriptionUsageBar(
                  usage: usage,
                  foreground: secondary,
                  trackColor: isCurrent ? scheme.onPrimaryContainer : null,
                ),
              ),
            ],
            if (item.updatedAt != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                l10n.t(
                  'profiles.traffic.lastUpdate',
                  args: <String, Object?>{
                    'time': formatMinute(item.updatedAt!),
                  },
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: secondary),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _openMenu(BuildContext context) async {
    final l10n = context.l10n;
    final selected = await showModalBottomSheet<ProfileCardAction>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: SectionList(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.only(bottom: 8),
            sections: <SectionListSection>[
              SectionListSection(
                title: item.name,
                tiles: <SectionListTile>[
                  if (_canRefresh)
                    SectionListTile(
                      title: l10n.t('common.refresh'),
                      icon: Icons.refresh_rounded,
                      onTap: () => Navigator.of(
                        sheetContext,
                      ).pop(ProfileCardAction.refresh),
                    ),
                  SectionListTile(
                    title: l10n.t('profiles.editInfo.title'),
                    icon: Icons.tune_rounded,
                    onTap: () => Navigator.of(
                      sheetContext,
                    ).pop(ProfileCardAction.editInfo),
                  ),
                  SectionListTile(
                    title: l10n.t('profiles.editFile.title'),
                    icon: Icons.description_outlined,
                    onTap: () => Navigator.of(
                      sheetContext,
                    ).pop(ProfileCardAction.editFile),
                  ),
                  SectionListTile(
                    title: l10n.t('profiles.editRules.title'),
                    icon: Icons.rule_rounded,
                    onTap: () => Navigator.of(
                      sheetContext,
                    ).pop(ProfileCardAction.editRules),
                  ),
                  SectionListTile(
                    title: l10n.t('profiles.editFile.override'),
                    icon: Icons.layers_outlined,
                    onTap: () => Navigator.of(
                      sheetContext,
                    ).pop(ProfileCardAction.editOverride),
                  ),
                  if (_canRefresh)
                    SectionListTile(
                      title: l10n.t('profiles.qrCode.show'),
                      icon: Icons.qr_code_2_rounded,
                      onTap: () => Navigator.of(
                        sheetContext,
                      ).pop(ProfileCardAction.showQrCode),
                    ),
                  if ((item.home ?? '').isNotEmpty)
                    SectionListTile(
                      title: l10n.t('profiles.home'),
                      icon: Icons.open_in_new_rounded,
                      onTap: () => Navigator.of(
                        sheetContext,
                      ).pop(ProfileCardAction.openHome),
                    ),
                  SectionListTile(
                    title: l10n.t('common.delete'),
                    icon: Icons.delete_outline_rounded,
                    destructive: true,
                    onTap: () => Navigator.of(
                      sheetContext,
                    ).pop(ProfileCardAction.delete),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (selected != null) onAction(selected);
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.label, this.foreground, this.filled = false});

  final String label;
  final Color? foreground;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final Color color = foreground ?? scheme.primary;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: ShapeDecoration(
        color: filled ? color.withValues(alpha: 0.16) : null,
        shape: StadiumBorder(
          side: BorderSide(color: color.withValues(alpha: 0.55)),
        ),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}
