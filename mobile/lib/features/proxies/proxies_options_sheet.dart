/// The display-options sheet behind the app bar's tune button.
///
/// Everything the desktop app scattered across three header icon buttons plus
/// its settings page — view, sort, hide-unavailable, card size, layout, column
/// count — in one place, because a phone app bar has room for two actions, not
/// six.
///
/// Presentational on purpose: values in, callbacks out. The page wraps it in a
/// `Consumer` so it can be exercised in a widget test without a running core.
library;

import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../l10n/aiko_l10n.dart';
import '../../theme/app_theme.dart';
import '../../widgets/widgets.dart';
import 'proxies_prefs.dart';
import 'proxy_strings.dart';

/// Column counts the sheet offers. `auto` derives the count from the width;
/// the rest pin it, matching the desktop's `proxyCols` setting.
const List<String> kProxyColumnChoices = <String>['auto', '1', '2', '3', '4'];

const Map<String, String> _columnLabelKeys = <String, String>{
  'auto': 'mihomo.proxyColumns.auto',
  '1': 'mihomo.proxyColumns.one',
  '2': 'mihomo.proxyColumns.two',
  '3': 'mihomo.proxyColumns.three',
  '4': 'mihomo.proxyColumns.four',
};

class ProxiesOptionsSheet extends StatelessWidget {
  const ProxiesOptionsSheet({
    super.key,
    required this.viewType,
    required this.sortOrder,
    required this.hideUnavailable,
    required this.density,
    required this.layout,
    required this.proxyCols,
    required this.onViewTypeChanged,
    required this.onSortOrderChanged,
    required this.onHideUnavailableChanged,
    required this.onDensityChanged,
    required this.onLayoutChanged,
    required this.onProxyColsChanged,
    this.onExpandAll,
    this.onCollapseAll,
  });

  final ProxiesViewType viewType;
  final ProxySortOrder sortOrder;
  final bool hideUnavailable;
  final ProxyCardDensity density;
  final ProxiesLayout layout;
  final String proxyCols;

  final ValueChanged<ProxiesViewType> onViewTypeChanged;
  final ValueChanged<ProxySortOrder> onSortOrderChanged;
  final ValueChanged<bool> onHideUnavailableChanged;
  final ValueChanged<ProxyCardDensity> onDensityChanged;
  final ValueChanged<ProxiesLayout> onLayoutChanged;
  final ValueChanged<String> onProxyColsChanged;

  /// Accordion-only actions. Omitted in the tab view, where there is nothing
  /// to expand.
  final VoidCallback? onExpandAll;
  final VoidCallback? onCollapseAll;

  @override
  Widget build(BuildContext context) {
    final l10n = AikoL10n.of(context);

    // The layout nudge only means something while the column count is derived
    // from the width; an explicit choice overrides it outright.
    final layoutEnabled = int.tryParse(proxyCols.trim()) == null;

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const _DragHandle(),
            _IconChoiceRow<ProxiesViewType>(
              icon: Icons.dashboard_customize_outlined,
              value: viewType,
              onChanged: onViewTypeChanged,
              options: <ProxiesViewType, String>{
                ProxiesViewType.tab: proxyText(
                  l10n,
                  'proxies.view.tab',
                  'sider.cards.proxies',
                ),
                ProxiesViewType.list: proxyText(
                  l10n,
                  'proxies.view.list',
                  'proxies.title',
                ),
              },
            ),
            _IconChoiceRow<ProxySortOrder>(
              icon: Icons.sort_rounded,
              value: sortOrder,
              onChanged: onSortOrderChanged,
              options: <ProxySortOrder, String>{
                ProxySortOrder.byDefault: l10n.t('proxies.order.default'),
                ProxySortOrder.byDelay: l10n.t('proxies.order.delay'),
                ProxySortOrder.byName: l10n.t('proxies.order.name'),
              },
            ),
            SwitchListTile.adaptive(
              value: hideUnavailable,
              onChanged: onHideUnavailableChanged,
              secondary: const Icon(Icons.visibility_off_outlined),
              title: Text(l10n.t('proxies.hideUnavailable.disabled')),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: AikoDims.pagePadding,
              ),
            ),
            if (onExpandAll != null || onCollapseAll != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AikoDims.pagePadding,
                  0,
                  AikoDims.pagePadding,
                  4,
                ),
                child: Row(
                  children: <Widget>[
                    if (onExpandAll != null)
                      TextButton.icon(
                        onPressed: onExpandAll,
                        icon: const Icon(Icons.unfold_more_rounded, size: 18),
                        label: Text(l10n.t('proxies.expandAll')),
                      ),
                    if (onCollapseAll != null)
                      TextButton.icon(
                        onPressed: onCollapseAll,
                        icon: const Icon(Icons.unfold_less_rounded, size: 18),
                        label: Text(l10n.t('proxies.collapseAll')),
                      ),
                  ],
                ),
              ),
            SectionListHeader(title: l10n.t('proxies.density.title')),
            _ChoiceChips<ProxyCardDensity>(
              value: density,
              onChanged: onDensityChanged,
              options: <ProxyCardDensity, String>{
                ProxyCardDensity.expand: l10n.t('proxies.density.expand'),
                ProxyCardDensity.shrink: l10n.t('proxies.density.shrink'),
                ProxyCardDensity.min: l10n.t('proxies.density.min'),
              },
            ),
            SectionListHeader(title: l10n.t('mihomo.proxyColumns.title')),
            _ChoiceChips<String>(
              value: proxyCols,
              onChanged: onProxyColsChanged,
              options: <String, String>{
                for (final choice in kProxyColumnChoices)
                  choice: l10n.t(_columnLabelKeys[choice]!),
              },
            ),
            SectionListHeader(title: l10n.t('proxies.layout.title')),
            Opacity(
              opacity: layoutEnabled ? 1 : 0.4,
              child: _ChoiceChips<ProxiesLayout>(
                value: layout,
                onChanged: layoutEnabled ? onLayoutChanged : null,
                options: <ProxiesLayout, String>{
                  ProxiesLayout.loose: l10n.t('proxies.layout.loose'),
                  ProxiesLayout.standard: l10n.t('proxies.layout.standard'),
                  ProxiesLayout.tight: l10n.t('proxies.layout.tight'),
                },
              ),
            ),
            const SizedBox(height: AikoDims.pagePadding),
          ],
        ),
      ),
    );
  }
}

class _DragHandle extends StatelessWidget {
  const _DragHandle();

  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      width: 32,
      height: 4,
      margin: const EdgeInsets.symmetric(vertical: 12),
      decoration: ShapeDecoration(
        color: Theme.of(
          context,
        ).colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
        shape: const StadiumBorder(),
      ),
    ),
  );
}

/// A leading icon standing in for a section title, then the choices.
///
/// Used where `assets/locales/` has labels for the options but no name for the
/// group they belong to; the icon carries that meaning instead of a raw key
/// leaking onto the screen.
class _IconChoiceRow<T> extends StatelessWidget {
  const _IconChoiceRow({
    required this.icon,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final IconData icon;
  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AikoDims.pagePadding,
      8,
      AikoDims.pagePadding,
      0,
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 12),
        Expanded(
          child: _ChoiceChips<T>(
            value: value,
            options: options,
            onChanged: onChanged,
            padding: EdgeInsets.zero,
          ),
        ),
      ],
    ),
  );
}

/// A wrapping row of single-select chips.
///
/// `Wrap` rather than `SegmentedButton` because five labelled columns choices
/// do not fit across a 360 dp phone, and a segmented button clips instead of
/// wrapping.
class _ChoiceChips<T> extends StatelessWidget {
  const _ChoiceChips({
    required this.value,
    required this.options,
    required this.onChanged,
    this.padding = const EdgeInsets.symmetric(horizontal: AikoDims.pagePadding),
  });

  final T value;
  final Map<T, String> options;

  /// `null` renders the group disabled.
  final ValueChanged<T>? onChanged;

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (final entry in options.entries)
          ChoiceChip(
            label: Text(entry.value),
            selected: entry.key == value,
            onSelected: onChanged == null
                ? null
                : (bool selected) {
                    if (selected) onChanged!(entry.key);
                  },
          ),
      ],
    ),
  );
}
