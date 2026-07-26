/// Language picker: "follow the system" plus the five shipped locales.
///
/// The choice is written to `LocaleSettingNotifier` (which `MaterialApp.locale`
/// reads, so the app re-renders immediately) and mirrored into
/// `AppConfig.language` so a backup carries it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../l10n/aiko_l10n.dart';
import '../../widgets/widgets.dart';
import 'settings_controls.dart';

const String kLanguageSettingsRoute = '/settings/language';

class LanguageSettingsPage extends ConsumerWidget {
  const LanguageSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AikoL10n l10n = context.l10n;
    final String? selected = ref.watch(localeSettingProvider);

    return AikoScaffold(
      title: l10n.t('settings.language'),
      body: SettingsBody(
        children: <Widget>[
          SettingsGroup(
            isFirst: true,
            children: <Widget>[
              SettingsChoiceTile(
                tileKey: const Key('language-system'),
                title: l10n.t('settings.language.system'),
                leading: const Icon(Icons.settings_suggest_outlined, size: 22),
                selected: selected == null,
                onTap: () => _select(context, ref, null),
              ),
              for (final AikoLocaleInfo info in kAikoLocales)
                SettingsChoiceTile(
                  tileKey: ValueKey<String>('language-${info.tag}'),
                  // The picker deliberately shows each language written in
                  // itself: a user who has the app in a language they cannot
                  // read still has to be able to find their own.
                  title: _nameFor(l10n, info),
                  subtitle: info.tag,
                  selected: selected == info.tag,
                  onTap: () => _select(context, ref, info.tag),
                ),
            ],
          ),
        ],
      ),
    );
  }

  static String _nameFor(AikoL10n l10n, AikoLocaleInfo info) {
    final String key = 'settings.language.name.${info.tag}';
    return l10n.has(key) ? l10n.t(key) : info.nativeName;
  }

  Future<void> _select(
    BuildContext context,
    WidgetRef ref,
    String? tag,
  ) async {
    try {
      await ref.read(localeSettingProvider.notifier).setLocaleTag(tag);
    } catch (error) {
      if (context.mounted) {
        showAikoSnack(context, context.l10n.t('common.saveFailed'), error: true);
      }
      return;
    }
    // Mirrored, not authoritative — a config.json failure must not roll back a
    // language the user can already see applied.
    try {
      await ref.read(appConfigProvider.notifier).update(
        (AppConfig current) => tag == null
            ? current.copyWith(clearLanguage: true)
            : current.copyWith(language: tag),
      );
    } catch (_) {
      // Intentionally ignored; see above.
    }
  }
}
