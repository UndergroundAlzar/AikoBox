/// Dashboard card layout — the Android form of the desktop's sidebar-card
/// editor (`settings/sider-config.tsx`).
///
/// Writes `AppConfig.cardOrder` and `AppConfig.cardStatus`, which are exactly
/// the two fields the dashboard's staggered grid reads. `CardStatus.colSpan2`
/// is a full-width card, `colSpan1` a half-width one, `hidden` is off.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../l10n/aiko_l10n.dart';
import '../../theme/theme.dart';
import '../../widgets/widgets.dart';
import 'settings_controls.dart';

const String kDashboardCardsRoute = '/settings/dashboard-cards';

/// l10n key for each dashboard card, reusing the desktop's sidebar strings so
/// the wording matches between the two clients.
const Map<String, String> kCardLabelKeys = <String, String>{
  'network': 'sider.cards.network',
  'mode': 'sider.cards.outbound.title',
  'profile': 'sider.cards.profiles',
  'proxy': 'sider.cards.proxies',
  'connection': 'sider.cards.connections',
  'usage': 'sider.cards.trafficUsage',
  'mihomo': 'sider.cards.core',
  'rule': 'sider.cards.rules',
  'dns': 'sider.cards.dns',
  'sniff': 'sider.cards.sniff',
  'resource': 'sider.cards.resources',
  'log': 'sider.cards.logs',
};

/// Fills in cards a config written by an older build does not mention, and
/// drops keys this build no longer has a card for.
List<String> normaliseCardOrder(List<String> saved) {
  final Set<String> seen = <String>{};
  final List<String> result = <String>[];
  for (final String key in saved) {
    if (kCardLabelKeys.containsKey(key) && seen.add(key)) result.add(key);
  }
  for (final String key in kDefaultCardOrder) {
    if (seen.add(key)) result.add(key);
  }
  return result;
}

class DashboardCardsPage extends ConsumerWidget {
  const DashboardCardsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AikoL10n l10n = context.l10n;
    final AppConfig config = ref.watch(appConfigProvider);
    final List<String> order = normaliseCardOrder(config.cardOrder);

    return AikoScaffold(
      title: l10n.t('dashboard.cards.title'),
      actions: <Widget>[
        IconButton(
          key: const Key('cards-reset'),
          tooltip: l10n.t('dashboard.cards.reset'),
          icon: const Icon(Icons.restart_alt_rounded),
          onPressed: () => saveAppConfig(
            context,
            ref,
            (AppConfig c) => c.copyWith(
              cardOrder: kDefaultCardOrder,
              cardStatus: AppConfig.defaults.cardStatus,
            ),
          ),
        ),
      ],
      body: ReorderableListView.builder(
        buildDefaultDragHandles: false,
        padding: const EdgeInsets.only(bottom: AikoDims.fabClearance),
        header: SettingsNote(
          l10n.t('dashboard.cards.hint'),
          icon: Icons.info_outline_rounded,
        ),
        itemCount: order.length,
        // `onReorderItem`, not the deprecated `onReorder`: it hands back a
        // newIndex that already accounts for the item having been lifted out.
        onReorderItem: (int oldIndex, int newIndex) {
          final List<String> next = List<String>.of(order);
          next.insert(newIndex, next.removeAt(oldIndex));
          saveAppConfig(
            context,
            ref,
            (AppConfig c) => c.copyWith(cardOrder: next),
          );
        },
        itemBuilder: (BuildContext context, int index) {
          final String key = order[index];
          final CardStatus status = config.statusOfCard(key);
          return ListTile(
            key: ValueKey<String>('card-$key'),
            leading: ReorderableDragStartListener(
              index: index,
              child: const Icon(Icons.drag_indicator_rounded, size: 22),
            ),
            title: Text(l10n.t(kCardLabelKeys[key] ?? key)),
            subtitle: Text(cardStatusLabel(l10n, status)),
            trailing: Icon(
              status.isVisible
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              size: 20,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            onTap: () async {
              final CardStatus? picked = await showAikoOptionSheet<CardStatus>(
                context,
                title: l10n.t(kCardLabelKeys[key] ?? key),
                selected: status,
                options: <AikoChoiceOption<CardStatus>>[
                  for (final CardStatus value in CardStatus.values)
                    AikoChoiceOption<CardStatus>(
                      value: value,
                      label: cardStatusLabel(l10n, value),
                    ),
                ],
              );
              if (picked == null || !context.mounted) return;
              await saveAppConfig(
                context,
                ref,
                (AppConfig c) => c.copyWith(
                  cardStatus: <String, CardStatus>{...c.cardStatus, key: picked},
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// Localised name of a [CardStatus], reusing the desktop's sidebar sizes.
String cardStatusLabel(AikoL10n l10n, CardStatus status) => switch (status) {
  CardStatus.colSpan2 => l10n.t('sider.size.large'),
  CardStatus.colSpan1 => l10n.t('sider.size.small'),
  CardStatus.hidden => l10n.t('sider.size.hidden'),
};
