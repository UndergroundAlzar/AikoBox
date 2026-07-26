/// Android platform guidance.
///
/// The three things that decide whether a phone keeps a VPN alive — always-on
/// VPN, battery-optimisation exemption, and the Quick Settings tile — all live
/// in system UI that only the OS can present. There is no method channel for
/// opening those screens today, so this page explains where they are instead of
/// offering a button that would silently do nothing.
library;

import 'package:flutter/material.dart';

import '../../l10n/aiko_l10n.dart';
import '../../theme/theme.dart';
import '../../widgets/widgets.dart';
import 'settings_controls.dart';

const String kAndroidSettingsRoute = '/settings/android';

class AndroidSettingsPage extends StatelessWidget {
  const AndroidSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final AikoL10n l10n = context.l10n;

    return AikoScaffold(
      title: l10n.t('settings.section.android'),
      body: SettingsBody(
        padding: const EdgeInsets.fromLTRB(
          AikoDims.pagePadding,
          12,
          AikoDims.pagePadding,
          AikoDims.fabClearance,
        ),
        children: <Widget>[
          _GuidanceCard(
            icon: Icons.vpn_lock_rounded,
            label: l10n.t('vpn.alwaysOn.title'),
            paragraphs: <String>[
              l10n.t('vpn.alwaysOn.description'),
              '${l10n.t('vpn.alwaysOn.blockConnections')} — '
                  '${l10n.t('vpn.alwaysOn.blockHint')}',
            ],
          ),
          const SizedBox(height: AikoDims.gridSpacing),
          _GuidanceCard(
            icon: Icons.battery_saver_rounded,
            label: l10n.t('battery.title'),
            paragraphs: <String>[
              l10n.t('battery.description'),
              l10n.t('battery.notExempted'),
            ],
          ),
          const SizedBox(height: AikoDims.gridSpacing),
          _GuidanceCard(
            icon: Icons.dashboard_rounded,
            label: l10n.t('tile.hint.title'),
            paragraphs: <String>[l10n.t('tile.hint.description')],
          ),
          const SizedBox(height: AikoDims.gridSpacing),
          _GuidanceCard(
            icon: Icons.health_and_safety_outlined,
            label: l10n.t('vpn.healthCheck.title'),
            paragraphs: <String>[l10n.t('vpn.healthCheck.message')],
          ),
        ],
      ),
    );
  }
}

class _GuidanceCard extends StatelessWidget {
  const _GuidanceCard({
    required this.icon,
    required this.label,
    required this.paragraphs,
  });

  final IconData icon;
  final String label;
  final List<String> paragraphs;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return CommonCard(
      icon: icon,
      label: label,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (int i = 0; i < paragraphs.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(height: 8),
            Text(
              paragraphs[i],
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
