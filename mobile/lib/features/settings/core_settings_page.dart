/// Core settings — the Android-meaningful subset of the desktop's
/// `settings/mihomo-config.tsx` plus the two knobs that only exist here
/// (`auto_redirect` on the tun inbound, and the live outbound mode).
///
/// Everything on this page either changes the running core immediately or is
/// read by `AikoCoreController` on the next start. Settings that the Dart core
/// layer does not yet consume are deliberately absent rather than shipped as
/// switches that do nothing.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../l10n/aiko_l10n.dart';
import '../../widgets/widgets.dart';
import 'app_info.dart';
import 'settings_controls.dart';

const String kCoreSettingsRoute = '/settings/core';

class CoreSettingsPage extends ConsumerStatefulWidget {
  const CoreSettingsPage({super.key});

  @override
  ConsumerState<CoreSettingsPage> createState() => _CoreSettingsPageState();
}

class _CoreSettingsPageState extends ConsumerState<CoreSettingsPage> {
  bool _restarting = false;

  @override
  Widget build(BuildContext context) {
    final AikoL10n l10n = context.l10n;
    final AppConfig config = ref.watch(appConfigProvider);
    final CoreStatus status = ref.watch(coreStatusProvider);
    final bool running = status.state == CoreState.running;
    final AsyncValue<OutboundMode> mode = ref.watch(outboundModeProvider);
    final AsyncValue<String> libboxVersion = ref.watch(coreVersionProvider);

    return AikoScaffold(
      title: l10n.t('mihomo.title'),
      body: SettingsBody(
        children: <Widget>[
          // ---------------------------------------------------------------
          SettingsGroup(
            isFirst: true,
            title: l10n.t('outbound.title'),
            children: <Widget>[
              AikoChoiceChips<OutboundMode>(
                options: <AikoChoiceOption<OutboundMode>>[
                  AikoChoiceOption<OutboundMode>(
                    value: OutboundMode.rule,
                    label: l10n.t('outbound.modes.rule'),
                    icon: Icons.rule_rounded,
                  ),
                  AikoChoiceOption<OutboundMode>(
                    value: OutboundMode.global,
                    label: l10n.t('outbound.modes.global'),
                    icon: Icons.public_rounded,
                  ),
                  AikoChoiceOption<OutboundMode>(
                    value: OutboundMode.direct,
                    label: l10n.t('outbound.modes.direct'),
                    icon: Icons.arrow_forward_rounded,
                  ),
                ],
                value: mode.value ?? OutboundMode.rule,
                enabled: running,
                onChanged: (OutboundMode next) => _setMode(next),
              ),
              if (!running)
                SettingsNote(
                  l10n.t('dashboard.core.notRunning'),
                  icon: Icons.info_outline_rounded,
                ),
            ],
          ),

          // ---------------------------------------------------------------
          SettingsGroup(
            title: l10n.t('settings.section.core'),
            children: <Widget>[
              SettingsValueTile(
                tileKey: const Key('core-version'),
                title: l10n.t('mihomo.coreVersion'),
                icon: Icons.memory_rounded,
                showChevron: false,
                value: _coreVersionLabel(l10n, status, libboxVersion),
              ),
              SettingsValueTile(
                tileKey: const Key('core-restart'),
                title: l10n.t('mihomo.restart'),
                icon: Icons.restart_alt_rounded,
                showChevron: false,
                enabled: running && !_restarting,
                onTap: _restart,
              ),
              SettingsSwitchTile(
                tileKey: const Key('core-auto-close-connection'),
                title: l10n.t('mihomo.autoCloseConnection'),
                icon: Icons.link_off_rounded,
                value: config.autoCloseConnection,
                onChanged: (bool value) => saveAppConfig(
                  context,
                  ref,
                  (AppConfig c) => c.copyWith(autoCloseConnection: value),
                ),
              ),
            ],
          ),

          // ---------------------------------------------------------------
          SettingsGroup(
            title: l10n.t('tun.title'),
            children: <Widget>[
              SettingsSwitchTile(
                tileKey: const Key('core-auto-redirect'),
                title: l10n.t('tun.autoRedirect'),
                subtitle: l10n.t('common.notification.restartRequired'),
                icon: Icons.alt_route_rounded,
                value: config.autoRedirect,
                onChanged: (bool value) => saveAppConfig(
                  context,
                  ref,
                  (AppConfig c) => c.copyWith(autoRedirect: value),
                ),
              ),
              // `tun.stack`, `ipv6`, `allow-lan` and the inbound ports come out
              // of the profile through the converter; the Dart core layer has
              // no override hook for them yet, so they are not offered here.
            ],
          ),

          // ---------------------------------------------------------------
          SettingsGroup(
            title: l10n.t('proxies.delay.test'),
            children: <Widget>[
              SettingsValueTile(
                tileKey: const Key('core-delay-url'),
                title: l10n.t('mihomo.delayTest.url'),
                icon: Icons.link_rounded,
                value: config.delayTestUrl,
                onTap: () => _editDelayUrl(config),
              ),
              SettingsValueTile(
                tileKey: const Key('core-delay-timeout'),
                title: l10n.t('mihomo.delayTest.timeout'),
                icon: Icons.timer_outlined,
                value: '${config.delayTestTimeout} ${l10n.t('unit.ms')}',
                onTap: () => _editNumber(
                  title: l10n.t('mihomo.delayTest.timeout'),
                  current: config.delayTestTimeout,
                  min: 500,
                  max: 60000,
                  hintText: l10n.t('mihomo.delayTest.timeoutPlaceholder'),
                  apply: (AppConfig c, int v) =>
                      c.copyWith(delayTestTimeout: v),
                ),
              ),
              SettingsValueTile(
                tileKey: const Key('core-delay-concurrency'),
                title: l10n.t('mihomo.delayTest.concurrency'),
                icon: Icons.speed_rounded,
                value: '${config.delayTestConcurrency}',
                onTap: () => _editNumber(
                  title: l10n.t('mihomo.delayTest.concurrency'),
                  current: config.delayTestConcurrency,
                  min: 1,
                  max: 64,
                  hintText: l10n.t('mihomo.delayTest.concurrencyPlaceholder'),
                  apply: (AppConfig c, int v) =>
                      c.copyWith(delayTestConcurrency: v),
                ),
              ),
            ],
          ),

          // ---------------------------------------------------------------
          SettingsGroup(
            title: l10n.t('logs.title'),
            children: <Widget>[
              SettingsValueTile(
                tileKey: const Key('core-log-level'),
                title: l10n.t('mihomo.logLevel'),
                icon: Icons.tune_rounded,
                value: logLevelLabel(l10n, config.logLevel),
                onTap: () => _pickLogLevel(config),
              ),
              SettingsValueTile(
                tileKey: const Key('core-log-lines'),
                title: l10n.t('logs.title'),
                subtitle: l10n.t(
                  'logs.bufferHint',
                  args: <String, Object?>{'count': config.maxLogLines},
                ),
                icon: Icons.subject_rounded,
                onTap: () => _editNumber(
                  title: l10n.t('logs.title'),
                  current: config.maxLogLines,
                  min: 100,
                  max: 20000,
                  apply: (AppConfig c, int v) => c.copyWith(maxLogLines: v),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _coreVersionLabel(
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

  Future<void> _setMode(OutboundMode next) async {
    try {
      await ref.read(outboundModeProvider.notifier).setMode(next);
    } catch (_) {
      if (mounted) {
        showAikoSnack(
          context,
          context.l10n.t('common.error.updateCoreConfigFailed'),
          error: true,
        );
      }
    }
  }

  Future<void> _restart() async {
    setState(() => _restarting = true);
    try {
      final CoreController controller = ref.read(coreControllerProvider);
      await controller.stop();
      await controller.start();
    } catch (_) {
      if (mounted) {
        showAikoSnack(
          context,
          context.l10n.t('common.error.restartCoreFailed'),
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => _restarting = false);
    }
  }

  Future<void> _editDelayUrl(AppConfig config) async {
    final AikoL10n l10n = context.l10n;
    final String? value = await showAikoTextSheet(
      context,
      title: l10n.t('mihomo.delayTest.url'),
      initialValue: config.delayTestUrl,
      hintText: l10n.t('mihomo.delayTest.urlPlaceholder'),
      keyboardType: TextInputType.url,
      validate: (String raw) {
        final Uri? parsed = Uri.tryParse(raw.trim());
        return parsed != null &&
            parsed.hasScheme &&
            (parsed.scheme == 'http' || parsed.scheme == 'https') &&
            parsed.host.isNotEmpty;
      },
    );
    if (value == null || !mounted) return;
    await saveAppConfig(
      context,
      ref,
      (AppConfig c) => c.copyWith(delayTestUrl: value.trim()),
    );
  }

  Future<void> _editNumber({
    required String title,
    required int current,
    required int min,
    required int max,
    required AppConfig Function(AppConfig config, int value) apply,
    String? hintText,
  }) async {
    final int? value = await showAikoNumberSheet(
      context,
      title: title,
      initialValue: current,
      min: min,
      max: max,
      hintText: hintText,
    );
    if (value == null || !mounted) return;
    await saveAppConfig(context, ref, (AppConfig c) => apply(c, value));
  }

  Future<void> _pickLogLevel(AppConfig config) async {
    final AikoL10n l10n = context.l10n;
    final LogLevel? picked = await showAikoOptionSheet<LogLevel>(
      context,
      title: l10n.t('mihomo.selectLogLevel'),
      selected: config.logLevel,
      options: <AikoChoiceOption<LogLevel>>[
        for (final LogLevel level in LogLevel.values)
          AikoChoiceOption<LogLevel>(
            value: level,
            label: logLevelLabel(l10n, level),
          ),
      ],
    );
    if (picked == null || !mounted) return;
    await saveAppConfig(
      context,
      ref,
      (AppConfig c) => c.copyWith(logLevel: picked),
    );
  }
}

/// Localised name of a [LogLevel], using the desktop's key set.
String logLevelLabel(AikoL10n l10n, LogLevel level) => switch (level) {
  LogLevel.silent => l10n.t('mihomo.silent'),
  LogLevel.error => l10n.t('mihomo.error'),
  LogLevel.warning => l10n.t('mihomo.warning'),
  LogLevel.info => l10n.t('mihomo.info'),
  LogLevel.debug => l10n.t('mihomo.debug'),
};
