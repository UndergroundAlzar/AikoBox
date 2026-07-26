/// The dashboard layout editor.
///
/// The desktop lets you drag sider cards around and cycle each one through
/// `col-span-2` / `col-span-1` / `hidden`. This is the same model in a bottom
/// sheet: drag to reorder, three-way size control per card, and a reset. Every
/// change is written straight through `AppConfig` — there is no "save" button,
/// because there is nothing to lose by applying immediately and a phone user
/// should be able to back out of a sheet without wondering whether their
/// changes stuck.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../l10n/aiko_l10n.dart';
import '../../theme/app_theme.dart';
import 'dashboard_cards.dart';
import 'dashboard_error.dart';

/// Opens the layout editor.
Future<void> showDashboardLayoutSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (BuildContext sheetContext) => const DashboardLayoutEditor(),
  );
}

/// The editor body. Exposed separately so it can be tested without a route.
class DashboardLayoutEditor extends ConsumerStatefulWidget {
  const DashboardLayoutEditor({super.key});

  @override
  ConsumerState<DashboardLayoutEditor> createState() =>
      _DashboardLayoutEditorState();
}

class _DashboardLayoutEditorState extends ConsumerState<DashboardLayoutEditor> {
  /// Local copy so a drag lands instantly instead of waiting for a disk write.
  List<String>? _order;

  List<String> _resolvedOrder(AppConfig config) =>
      _order ?? resolveDashboardCardOrder(config.cardOrder);

  Future<void> _persist(AppConfig Function(AppConfig) updater) async {
    try {
      await ref.read(appConfigProvider.notifier).update(updater);
    } catch (error) {
      if (!mounted) return;
      await showDashboardErrorSheet(context, error);
    }
  }

  /// `onReorderItem` hands over an index that already accounts for the removal
  /// of the dragged row, unlike the deprecated `onReorder`.
  void _reorder(List<String> current, int oldIndex, int newIndex) {
    final List<String> next = List<String>.of(current);
    next.insert(newIndex, next.removeAt(oldIndex));
    setState(() => _order = next);
    _persist((AppConfig config) => config.copyWith(cardOrder: next));
  }

  void _setStatus(AppConfig config, String key, CardStatus status) {
    final Map<String, CardStatus> next = <String, CardStatus>{
      for (final String cardKey in _resolvedOrder(config))
        cardKey: config.statusOfCard(cardKey),
      key: status,
    };
    _persist((AppConfig current) => current.copyWith(cardStatus: next));
  }

  void _reset() {
    final List<String> order = resolveDashboardCardOrder(const <String>[]);
    setState(() => _order = order);
    _persist(
      (AppConfig config) => config.copyWith(
        cardOrder: order,
        cardStatus: defaultDashboardCardStatus(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AikoL10n l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    final AppConfig config = ref.watch(appConfigProvider);
    final List<String> order = _resolvedOrder(config);

    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.78,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
            child: Text(
              l10n.t('dashboard.cards.title'),
              style: theme.textTheme.titleLarge?.copyWith(
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Text(
              l10n.t('dashboard.cards.hint'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: ReorderableListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              buildDefaultDragHandles: false,
              itemCount: order.length,
              onReorderItem: (int oldIndex, int newIndex) =>
                  _reorder(order, oldIndex, newIndex),
              itemBuilder: (BuildContext context, int index) {
                final String key = order[index];
                final DashboardCardSpec spec = dashboardCardSpec(key)!;
                return _LayoutRow(
                  key: ValueKey<String>('layout-row-$key'),
                  index: index,
                  spec: spec,
                  status: config.statusOfCard(key),
                  onStatusChanged: (CardStatus status) =>
                      _setStatus(config, key, status),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _reset,
                    icon: const Icon(Icons.restart_alt_rounded, size: 18),
                    label: Text(
                      l10n.t('dashboard.cards.reset'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: Text(
                      l10n.t('common.done'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LayoutRow extends StatelessWidget {
  const _LayoutRow({
    super.key,
    required this.index,
    required this.spec,
    required this.status,
    required this.onStatusChanged,
  });

  final int index;
  final DashboardCardSpec spec;
  final CardStatus status;
  final ValueChanged<CardStatus> onStatusChanged;

  @override
  Widget build(BuildContext context) {
    final AikoL10n l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    final bool hidden = status == CardStatus.hidden;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          ReorderableDragStartListener(
            index: index,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              child: Icon(
                Icons.drag_handle_rounded,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Icon(
            spec.icon,
            size: AikoDims.cardHeaderIconSize,
            color: hidden
                ? theme.colorScheme.onSurfaceVariant
                : theme.colorScheme.primary,
          ),
          const SizedBox(width: AikoDims.cardHeaderGap),
          Expanded(
            child: Text(
              l10n.t(spec.labelKey),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: hidden
                    ? theme.colorScheme.onSurfaceVariant
                    : theme.colorScheme.onSurface,
              ),
            ),
          ),
          const SizedBox(width: 8),
          SegmentedButton<CardStatus>(
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            segments: <ButtonSegment<CardStatus>>[
              ButtonSegment<CardStatus>(
                value: CardStatus.colSpan2,
                icon: const Icon(Icons.crop_16_9_rounded, size: 18),
                tooltip: l10n.t('sider.size.large'),
              ),
              ButtonSegment<CardStatus>(
                value: CardStatus.colSpan1,
                icon: const Icon(Icons.crop_square_rounded, size: 18),
                tooltip: l10n.t('sider.size.small'),
              ),
              ButtonSegment<CardStatus>(
                value: CardStatus.hidden,
                icon: const Icon(Icons.visibility_off_rounded, size: 18),
                tooltip: l10n.t('sider.size.hidden'),
              ),
            ],
            selected: <CardStatus>{status},
            onSelectionChanged: (Set<CardStatus> selection) {
              if (selection.isEmpty) return;
              onStatusChanged(selection.first);
            },
          ),
        ],
      ),
    );
  }
}
