/// Application settings — the presentation and networking preferences that
/// live in `AppConfig` and are read by the proxies, connections and profiles
/// screens.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../l10n/aiko_l10n.dart';
import '../../widgets/widgets.dart';
import 'dashboard_cards_page.dart';
import 'settings_controls.dart';

const String kAppSettingsRoute = '/settings/app';

/// The `proxyCols` values the desktop persists.
const List<String> kProxyColumnValues = <String>['auto', '1', '2', '3', '4'];

/// The `connectionOrderBy` values the desktop persists.
const List<String> kConnectionOrderValues = <String>[
  'time',
  'upload',
  'download',
  'uploadSpeed',
  'downloadSpeed',
];

class AppSettingsPage extends ConsumerWidget {
  const AppSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AikoL10n l10n = context.l10n;
    final AppConfig config = ref.watch(appConfigProvider);
    final int timeoutSeconds = (config.subscriptionTimeout / 1000).round();

    return AikoScaffold(
      title: l10n.t('settings.title'),
      body: SettingsBody(
        children: <Widget>[
          // ---------------------------------------------------------- proxies
          SettingsGroup(
            isFirst: true,
            title: l10n.t('proxies.title'),
            children: <Widget>[
              SettingsValueTile(
                tileKey: const Key('app-proxy-display-mode'),
                title: l10n.t('proxies.density.title'),
                icon: Icons.view_agenda_outlined,
                value: _proxyModeLabel(l10n, config.proxyDisplayMode),
                onTap: () async {
                  final String? picked = await showAikoOptionSheet<String>(
                    context,
                    title: l10n.t('proxies.density.title'),
                    selected: config.proxyDisplayMode,
                    options: <AikoChoiceOption<String>>[
                      AikoChoiceOption<String>(
                        value: 'simple',
                        label: l10n.t('proxies.mode.simple'),
                      ),
                      AikoChoiceOption<String>(
                        value: 'full',
                        label: l10n.t('proxies.mode.full'),
                      ),
                    ],
                  );
                  if (picked == null || !context.mounted) return;
                  await saveAppConfig(
                    context,
                    ref,
                    (AppConfig c) => c.copyWith(proxyDisplayMode: picked),
                  );
                },
              ),
              SettingsValueTile(
                tileKey: const Key('app-proxy-order'),
                title: l10n.t('connections.orderBy'),
                icon: Icons.sort_rounded,
                value: _proxyOrderLabel(l10n, config.proxyDisplayOrder),
                onTap: () async {
                  final ProxySortOrder? picked =
                      await showAikoOptionSheet<ProxySortOrder>(
                        context,
                        title: l10n.t('connections.orderBy'),
                        selected: config.proxyDisplayOrder,
                        options: <AikoChoiceOption<ProxySortOrder>>[
                          for (final ProxySortOrder order
                              in ProxySortOrder.values)
                            AikoChoiceOption<ProxySortOrder>(
                              value: order,
                              label: _proxyOrderLabel(l10n, order),
                            ),
                        ],
                      );
                  if (picked == null || !context.mounted) return;
                  await saveAppConfig(
                    context,
                    ref,
                    (AppConfig c) => c.copyWith(proxyDisplayOrder: picked),
                  );
                },
              ),
              SettingsValueTile(
                tileKey: const Key('app-proxy-columns'),
                title: l10n.t('mihomo.proxyColumns.title'),
                icon: Icons.grid_view_rounded,
                value: _proxyColumnsLabel(l10n, config.proxyCols),
                onTap: () async {
                  final String? picked = await showAikoOptionSheet<String>(
                    context,
                    title: l10n.t('mihomo.proxyColumns.title'),
                    selected: config.proxyCols,
                    options: <AikoChoiceOption<String>>[
                      for (final String value in kProxyColumnValues)
                        AikoChoiceOption<String>(
                          value: value,
                          label: _proxyColumnsLabel(l10n, value),
                        ),
                    ],
                  );
                  if (picked == null || !context.mounted) return;
                  await saveAppConfig(
                    context,
                    ref,
                    (AppConfig c) => c.copyWith(proxyCols: picked),
                  );
                },
              ),
              SettingsSwitchTile(
                tileKey: const Key('app-hide-unavailable'),
                title: l10n.t('proxies.hideUnavailable.disabled'),
                icon: Icons.visibility_off_outlined,
                value: config.hideUnavailableProxies,
                onChanged: (bool value) => saveAppConfig(
                  context,
                  ref,
                  (AppConfig c) => c.copyWith(hideUnavailableProxies: value),
                ),
              ),
            ],
          ),

          // ------------------------------------------------------ connections
          SettingsGroup(
            title: l10n.t('connections.title'),
            children: <Widget>[
              ListTile(
                key: const Key('app-connection-order'),
                leading: const Icon(Icons.swap_vert_rounded, size: 22),
                title: Text(l10n.t('connections.orderBy')),
                subtitle: Text(
                  _connectionOrderLabel(l10n, config.connectionOrderBy),
                ),
                trailing: IconButton(
                  key: const Key('app-connection-direction'),
                  tooltip: l10n.t('connections.orderBy'),
                  icon: Icon(
                    config.connectionDirection == 'asc'
                        ? Icons.arrow_upward_rounded
                        : Icons.arrow_downward_rounded,
                  ),
                  onPressed: () => saveAppConfig(
                    context,
                    ref,
                    (AppConfig c) => c.copyWith(
                      connectionDirection:
                          c.connectionDirection == 'asc' ? 'desc' : 'asc',
                    ),
                  ),
                ),
                onTap: () async {
                  final String? picked = await showAikoOptionSheet<String>(
                    context,
                    title: l10n.t('connections.orderBy'),
                    selected: config.connectionOrderBy,
                    options: <AikoChoiceOption<String>>[
                      for (final String value in kConnectionOrderValues)
                        AikoChoiceOption<String>(
                          value: value,
                          label: _connectionOrderLabel(l10n, value),
                        ),
                    ],
                  );
                  if (picked == null || !context.mounted) return;
                  await saveAppConfig(
                    context,
                    ref,
                    (AppConfig c) => c.copyWith(connectionOrderBy: picked),
                  );
                },
              ),
            ],
          ),

          // ---------------------------------------------------------- general
          SettingsGroup(
            title: l10n.t('settings.general'),
            children: <Widget>[
              SettingsValueTile(
                tileKey: const Key('app-subscription-timeout'),
                title: l10n.t('settings.subscriptionTimeout'),
                icon: Icons.hourglass_bottom_rounded,
                value: '$timeoutSeconds ${l10n.t('common.seconds')}',
                onTap: () async {
                  final int? seconds = await showAikoNumberSheet(
                    context,
                    title: l10n.t('settings.subscriptionTimeout'),
                    initialValue: timeoutSeconds,
                    min: 30,
                    max: 600,
                  );
                  if (seconds == null || !context.mounted) return;
                  await saveAppConfig(
                    context,
                    ref,
                    (AppConfig c) =>
                        c.copyWith(subscriptionTimeout: seconds * 1000),
                  );
                },
              ),
              SettingsValueTile(
                tileKey: const Key('app-dashboard-cards'),
                title: l10n.t('dashboard.cards.title'),
                subtitle: l10n.t('dashboard.cards.hint'),
                icon: Icons.dashboard_customize_outlined,
                onTap: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    settings: const RouteSettings(name: kDashboardCardsRoute),
                    builder: (_) => const DashboardCardsPage(),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _proxyModeLabel(AikoL10n l10n, String mode) => mode == 'full'
      ? l10n.t('proxies.mode.full')
      : l10n.t('proxies.mode.simple');

  static String _proxyOrderLabel(AikoL10n l10n, ProxySortOrder order) =>
      switch (order) {
        ProxySortOrder.byDefault => l10n.t('proxies.order.default'),
        ProxySortOrder.byDelay => l10n.t('proxies.order.delay'),
        ProxySortOrder.byName => l10n.t('proxies.order.name'),
      };

  static String _proxyColumnsLabel(AikoL10n l10n, String value) =>
      switch (value) {
        '1' => l10n.t('mihomo.proxyColumns.one'),
        '2' => l10n.t('mihomo.proxyColumns.two'),
        '3' => l10n.t('mihomo.proxyColumns.three'),
        '4' => l10n.t('mihomo.proxyColumns.four'),
        _ => l10n.t('mihomo.proxyColumns.auto'),
      };

  static String _connectionOrderLabel(AikoL10n l10n, String value) =>
      switch (value) {
        'upload' => l10n.t('connections.uploadAmount'),
        'download' => l10n.t('connections.downloadAmount'),
        'uploadSpeed' => l10n.t('connections.uploadSpeed'),
        'downloadSpeed' => l10n.t('connections.downloadSpeed'),
        _ => l10n.t('connections.time'),
      };
}
