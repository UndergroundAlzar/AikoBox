/// The Tools tab — a sectioned `ListTile` list, per build contract §6.
///
/// Section headers are `primary`-tinted, every row has a leading icon, a title,
/// a subtitle showing the value that is currently in force, and thin dividers
/// between rows. Each row pushes a sub-page; nothing is edited in place here.
///
/// Pages this feature does not own (logs, connections, rules, external
/// resources) can be spliced in through [extraSections] — that is the seam the
/// app shell uses instead of this file guessing at other agents' routes.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../l10n/aiko_l10n.dart';
import '../../theme/theme.dart';
import '../../widgets/widgets.dart';
import '../about/about_page.dart';
import 'android_settings_page.dart';
import 'app_info.dart';
import 'app_settings_page.dart';
import 'backup_page.dart';
import 'core_settings_page.dart';
import 'dashboard_cards_page.dart';
import 'language_settings_page.dart';
import 'per_app_settings_page.dart';
import 'theme_settings_page.dart';

const String kToolsRoute = '/tools';

class ToolsPage extends ConsumerWidget {
  const ToolsPage({
    super.key,
    this.extraSections = const <SectionListSection>[],
    this.showAppBar = true,
  });

  /// Sections contributed by features outside `features/settings/**`, inserted
  /// just before the backup and about sections.
  final List<SectionListSection> extraSections;

  /// False when the app shell already draws the page title.
  final bool showAppBar;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AikoL10n l10n = context.l10n;
    final AppConfig config = ref.watch(appConfigProvider);
    final AikoThemeSettings theme = ref.watch(themeControllerProvider);
    final String? localeTag = ref.watch(localeSettingProvider);
    final CoreStatus status = ref.watch(coreStatusProvider);
    final String? appVersion = ref.watch(appPackageInfoProvider).value?.version;

    return AikoScaffold(
      showAppBar: showAppBar,
      title: l10n.t('nav.tools'),
      body: SectionList(
        sections: <SectionListSection>[
          SectionListSection(
            title: l10n.t('settings.section.appearance'),
            tiles: <SectionListTile>[
              SectionListTile(
                itemKey: const Key('tools-theme'),
                icon: Icons.palette_outlined,
                title: l10n.t('theme.title'),
                subtitle: _themeModeLabel(l10n, theme.themeMode),
                onTap: () => _push(
                  context,
                  kThemeSettingsRoute,
                  const ThemeSettingsPage(),
                ),
              ),
              SectionListTile(
                itemKey: const Key('tools-language'),
                icon: Icons.translate_rounded,
                title: l10n.t('settings.language'),
                subtitle: _languageLabel(l10n, localeTag),
                onTap: () => _push(
                  context,
                  kLanguageSettingsRoute,
                  const LanguageSettingsPage(),
                ),
              ),
            ],
          ),

          SectionListSection(
            title: l10n.t('settings.section.network'),
            tiles: <SectionListTile>[
              SectionListTile(
                itemKey: const Key('tools-per-app'),
                icon: Icons.apps_rounded,
                title: l10n.t('perApp.title'),
                subtitle: _perAppLabel(l10n, config),
                onTap: () => _push(
                  context,
                  kPerAppSettingsRoute,
                  const PerAppSettingsPage(),
                ),
              ),
            ],
          ),

          SectionListSection(
            title: l10n.t('settings.section.core'),
            tiles: <SectionListTile>[
              SectionListTile(
                itemKey: const Key('tools-core'),
                icon: Icons.memory_rounded,
                title: l10n.t('mihomo.title'),
                subtitle: status.version ?? l10n.t('dashboard.status.stopped'),
                onTap: () => _push(
                  context,
                  kCoreSettingsRoute,
                  const CoreSettingsPage(),
                ),
              ),
            ],
          ),

          SectionListSection(
            title: l10n.t('settings.section.general'),
            tiles: <SectionListTile>[
              SectionListTile(
                itemKey: const Key('tools-app'),
                icon: Icons.tune_rounded,
                title: l10n.t('settings.title'),
                subtitle: l10n.t('settings.general'),
                onTap: () =>
                    _push(context, kAppSettingsRoute, const AppSettingsPage()),
              ),
              SectionListTile(
                itemKey: const Key('tools-dashboard-cards'),
                icon: Icons.dashboard_customize_outlined,
                title: l10n.t('dashboard.cards.title'),
                subtitle: l10n.t('dashboard.cards.hint'),
                onTap: () => _push(
                  context,
                  kDashboardCardsRoute,
                  const DashboardCardsPage(),
                ),
              ),
            ],
          ),

          SectionListSection(
            title: l10n.t('settings.section.android'),
            tiles: <SectionListTile>[
              SectionListTile(
                itemKey: const Key('tools-android'),
                icon: Icons.phone_android_rounded,
                title: l10n.t('vpn.alwaysOn.title'),
                subtitle: l10n.t('battery.title'),
                onTap: () => _push(
                  context,
                  kAndroidSettingsRoute,
                  const AndroidSettingsPage(),
                ),
              ),
            ],
          ),

          ...extraSections,

          SectionListSection(
            title: l10n.t('settings.section.backup'),
            tiles: <SectionListTile>[
              SectionListTile(
                itemKey: const Key('tools-backup'),
                icon: Icons.settings_backup_restore_rounded,
                title: l10n.t('localBackup.title'),
                subtitle: l10n.t('localBackup.export.title'),
                onTap: () => _push(context, kBackupRoute, const BackupPage()),
              ),
            ],
          ),

          SectionListSection(
            title: l10n.t('settings.section.about'),
            tiles: <SectionListTile>[
              SectionListTile(
                itemKey: const Key('tools-about'),
                icon: Icons.info_outline_rounded,
                title: l10n.t('about.title'),
                subtitle: appVersion == null
                    ? l10n.t('app.tagline')
                    : '${l10n.t('app.name')} $appVersion',
                onTap: () => _push(context, kAboutRoute, const AboutPage()),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static void _push(BuildContext context, String route, Widget page) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        settings: RouteSettings(name: route),
        builder: (_) => page,
      ),
    );
  }

  static String _themeModeLabel(AikoL10n l10n, ThemeMode mode) =>
      switch (mode) {
        ThemeMode.system => l10n.t('settings.backgroundAuto'),
        ThemeMode.light => l10n.t('settings.backgroundLight'),
        ThemeMode.dark => l10n.t('settings.backgroundDark'),
      };

  static String _languageLabel(AikoL10n l10n, String? tag) {
    if (tag == null) return l10n.t('settings.language.system');
    final String key = 'settings.language.name.$tag';
    return l10n.has(key) ? l10n.t(key) : AikoL10n.infoForTag(tag).nativeName;
  }

  static String _perAppLabel(AikoL10n l10n, AppConfig config) {
    final String mode = switch (config.splitTunnelMode) {
      SplitTunnelMode.off => l10n.t('perApp.mode.off'),
      SplitTunnelMode.allow => l10n.t('perApp.mode.allowlist'),
      SplitTunnelMode.deny => l10n.t('perApp.mode.denylist'),
    };
    if (config.splitTunnelMode == SplitTunnelMode.off) return mode;
    return '$mode · ${l10n.plural('plural.apps', config.splitTunnelPackages.length)}';
  }
}
