/// About — versions, licence, third-party notices and the security policy.
///
/// AikoBox is GPL-3.0-only and links against sing-box (libbox). §7 of the build
/// contract makes the licence notice and the third-party attribution part of
/// shipping, not a nicety, so both are first-class rows here rather than buried
/// behind a "legal" submenu.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/providers.dart';
import '../../l10n/aiko_l10n.dart';
import '../../theme/theme.dart';
import '../../widgets/widgets.dart';
import '../settings/app_info.dart';
import '../settings/settings_controls.dart';

const String kAboutRoute = '/about';

/// Canonical project locations. `main` is the default branch (see
/// `.github/dependabot.yml`).
const String kAikoRepoUrl = 'https://github.com/UndergroundAlzar/AikoBox';
const String kAikoLicenseUrl = '$kAikoRepoUrl/blob/main/LICENSE';
const String kAikoThirdPartyUrl =
    '$kAikoRepoUrl/blob/main/THIRD_PARTY_NOTICES.md';
const String kAikoSecurityUrl = '$kAikoRepoUrl/blob/main/SECURITY.md';
const String kAikoDocsUrl = '$kAikoRepoUrl#readme';

/// SPDX identifier from `package.json`. Not a translatable string.
const String kAikoLicenseId = 'GPL-3.0-only';

class AboutPage extends ConsumerWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AikoL10n l10n = context.l10n;
    final PackageInfo? info = ref.watch(appPackageInfoProvider).value;
    final CoreStatus status = ref.watch(coreStatusProvider);
    final String coreVersion = _coreVersion(
      l10n,
      status,
      ref.watch(coreVersionProvider),
    );
    final String appVersion = info == null
        ? l10n.t('common.loading')
        : info.version;

    return AikoScaffold(
      title: l10n.t('about.title'),
      body: SettingsBody(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AikoDims.pagePadding,
              12,
              AikoDims.pagePadding,
              4,
            ),
            child: _AboutHeader(
              name: l10n.t('app.name'),
              tagline: l10n.t('app.tagline'),
            ),
          ),

          SettingsGroup(
            children: <Widget>[
              SettingsValueTile(
                tileKey: const Key('about-app-version'),
                title: l10n.t('actions.version.title'),
                subtitle: info == null
                    ? null
                    : '${l10n.t('about.buildNumber')} ${info.buildNumber}',
                icon: Icons.info_outline_rounded,
                showChevron: false,
                value: appVersion,
              ),
              SettingsValueTile(
                tileKey: const Key('about-core-version'),
                title: l10n.t('mihomo.coreVersion'),
                icon: Icons.memory_rounded,
                showChevron: false,
                value: coreVersion,
              ),
            ],
          ),

          SettingsGroup(
            title: l10n.t('about.license'),
            children: <Widget>[
              SettingsValueTile(
                tileKey: const Key('about-license'),
                title: l10n.t('about.license'),
                subtitle: kAikoLicenseId,
                icon: Icons.gavel_rounded,
                onTap: () => _open(context, kAikoLicenseUrl),
              ),
              SettingsValueTile(
                tileKey: const Key('about-third-party'),
                title: l10n.t('about.thirdParty'),
                icon: Icons.library_books_outlined,
                onTap: () => _open(context, kAikoThirdPartyUrl),
              ),
              SettingsValueTile(
                tileKey: const Key('about-security'),
                title: context.l10n.t('about.security'),
                icon: Icons.shield_outlined,
                onTap: () => _open(context, kAikoSecurityUrl),
              ),
            ],
          ),

          SettingsGroup(
            title: l10n.t('settings.section.about'),
            children: <Widget>[
              SettingsValueTile(
                tileKey: const Key('about-source'),
                title: l10n.t('about.sourceCode'),
                subtitle: l10n.t('settings.links.github'),
                icon: Icons.code_rounded,
                onTap: () => _open(context, kAikoRepoUrl),
              ),
              SettingsValueTile(
                tileKey: const Key('about-docs'),
                title: l10n.t('settings.links.docs'),
                icon: Icons.menu_book_rounded,
                onTap: () => _open(context, kAikoDocsUrl),
              ),
              SettingsValueTile(
                tileKey: const Key('about-diagnostics'),
                title: l10n.t('about.copyDiagnostics'),
                icon: Icons.copy_all_rounded,
                showChevron: false,
                onTap: () => _copyDiagnostics(context, ref, info, coreVersion),
              ),
            ],
          ),

          Padding(
            padding: const EdgeInsets.fromLTRB(
              AikoDims.pagePadding,
              24,
              AikoDims.pagePadding,
              8,
            ),
            child: Text(
              l10n.t(
                'about.copyright',
                args: <String, Object?>{'year': DateTime.now().year},
              ),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _coreVersion(
    AikoL10n l10n,
    CoreStatus status,
    AsyncValue<String> libboxVersion,
  ) {
    final String? live = status.version;
    if (live != null && live.isNotEmpty) return live;
    final String? reported = libboxVersion.value;
    if (reported != null && reported.isNotEmpty) return reported;
    return l10n.t('common.unknown');
  }

  Future<void> _open(BuildContext context, String url) async {
    bool opened = false;
    try {
      opened = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      // A device with no browser at all still must not crash the About page.
      opened = false;
    }
    if (!opened && context.mounted) {
      showAikoSnack(
        context,
        context.l10n.t('common.error.default'),
        error: true,
      );
    }
  }

  Future<void> _copyDiagnostics(
    BuildContext context,
    WidgetRef ref,
    PackageInfo? info,
    String coreVersion,
  ) async {
    final AppConfig config = ref.read(appConfigProvider);
    final AikoLocaleInfo locale = ref.read(activeLocaleInfoProvider);
    // Deliberately no profile names, no subscription URLs and no device
    // identifiers: this text is meant to be pasted into a public issue.
    final String report = <String>[
      'AikoBox ${info?.version ?? '?'} (${info?.buildNumber ?? '?'})',
      'package: ${info?.packageName ?? '?'}',
      'core: $coreVersion',
      'locale: ${locale.tag}',
      'theme: ${config.appTheme.wireName}, dynamic=${config.useDynamicColor}',
      'splitTunnel: ${config.splitTunnelMode.wireName} '
          '(${config.splitTunnelPackages.length})',
      'logLevel: ${config.logLevel.wireName}',
    ].join('\n');

    await Clipboard.setData(ClipboardData(text: report));
    if (context.mounted) {
      showAikoSnack(context, context.l10n.t('common.copied'));
    }
  }
}

class _AboutHeader extends StatelessWidget {
  const _AboutHeader({required this.name, required this.tagline});

  final String name;
  final String tagline;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return CommonCard(
      child: Row(
        children: <Widget>[
          Container(
            width: 56,
            height: 56,
            alignment: Alignment.center,
            decoration: ShapeDecoration(
              color: scheme.primaryContainer,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            child: Icon(
              Icons.rocket_launch_rounded,
              size: 28,
              color: scheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(name, style: theme.textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  tagline,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
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
