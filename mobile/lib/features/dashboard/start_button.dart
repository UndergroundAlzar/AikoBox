/// The morphing start/stop FAB and the VPN consent flow behind it.
///
/// The consent flow is deliberately two-stage. `CoreController.start()`
/// already calls `prepareVpn()` and, if consent is missing,
/// `requestVpnPermission()` — so the system dialog would appear on its own.
/// But N5 says nothing happens silently: the user taps a rocket and Android
/// throws up a scary system prompt about intercepting all their traffic. So
/// this asks `prepareVpn()` first and, when consent has *not* been granted,
/// explains what is about to be asked and why before letting the controller
/// trigger it.
///
/// Stopping is confirmed too, because on a phone the tunnel going down is not
/// a cosmetic event.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../l10n/aiko_l10n.dart';
import '../../widgets/widgets.dart';
import 'dashboard_error.dart';
import 'dashboard_navigation.dart';

class DashboardStartButton extends ConsumerStatefulWidget {
  const DashboardStartButton({super.key});

  @override
  ConsumerState<DashboardStartButton> createState() =>
      _DashboardStartButtonState();
}

class _DashboardStartButtonState extends ConsumerState<DashboardStartButton> {
  /// True from the tap until the controller has taken over, so the button is
  /// not tappable while a consent or confirmation sheet is open.
  bool _pending = false;

  @override
  Widget build(BuildContext context) {
    final AikoL10n l10n = context.l10n;
    final CoreStatus status = ref.watch(coreStatusProvider);
    final bool busy = status.isBusy || _pending;

    return AikoFab(
      running: status.isRunning,
      startedAt: status.startedAt,
      busy: busy,
      tooltip: status.isRunning
          ? l10n.t('dashboard.stop')
          : l10n.t('dashboard.start'),
      semanticLabel: status.isRunning
          ? l10n.t('dashboard.stop')
          : l10n.t('dashboard.start'),
      onPressed: busy ? null : () => _onPressed(status),
    );
  }

  Future<void> _onPressed(CoreStatus status) async {
    setState(() => _pending = true);
    try {
      if (status.isRunning) {
        await _stop();
      } else {
        await _start();
      }
    } finally {
      if (mounted) setState(() => _pending = false);
    }
  }

  Future<void> _stop() async {
    final AikoL10n l10n = context.l10n;
    final bool confirmed = await showAikoConfirmSheet(
      context,
      title: l10n.t('vpn.stopConfirm.title'),
      message: l10n.t('vpn.stopConfirm.content'),
      confirmLabel: l10n.t('dashboard.stop'),
      cancelLabel: l10n.t('common.cancel'),
      icon: Icons.pause_circle_outline_rounded,
      destructive: true,
    );
    if (!confirmed || !mounted) return;

    try {
      await ref.read(coreControllerProvider).stop();
    } catch (error) {
      if (!mounted) return;
      await showDashboardErrorSheet(context, error);
    }
  }

  Future<void> _start() async {
    final AikoL10n l10n = context.l10n;

    // Nothing to start: say so, and offer the one action that fixes it.
    if (ref.read(currentProfileProvider) == null) {
      final DashboardNavigate? navigate = ref.read(dashboardNavigateProvider);
      final bool go = await showAikoConfirmSheet(
        context,
        title: l10n.t('dashboard.noProfile.title'),
        message: l10n.t('profiles.empty.description'),
        confirmLabel: l10n.t('dashboard.noProfile.action'),
        cancelLabel: l10n.t('common.cancel'),
        icon: Icons.folder_off_outlined,
      );
      if (go) navigate?.call(DashboardDestination.profiles);
      return;
    }

    if (!await _ensureConsent()) return;
    if (!mounted) return;

    try {
      await ref.read(coreControllerProvider).start();
    } catch (error) {
      if (!mounted) return;
      final DashboardNavigate? navigate = ref.read(dashboardNavigateProvider);
      final bool offerProfiles =
          error is CoreStartException &&
          error.code == CoreStartException.codeNoProfile &&
          navigate != null;
      await showDashboardErrorSheet(
        context,
        error,
        actionLabel: offerProfiles
            ? l10n.t('dashboard.noProfile.action')
            : null,
        onAction: offerProfiles
            ? () => navigate.call(DashboardDestination.profiles)
            : null,
      );
    }
  }

  /// Explains the VPN prompt before Android shows it.
  ///
  /// Returns false only when the user backed out of the explanation — a
  /// refusal of the *system* dialog surfaces later as
  /// `E_VPN_PERMISSION_DENIED` from `start()`, which the error sheet already
  /// knows how to phrase.
  Future<bool> _ensureConsent() async {
    bool granted;
    try {
      granted = await ref.read(coreChannelProvider).prepareVpn();
    } catch (_) {
      // A host that cannot answer is treated as "not granted": the worst case
      // is one extra explanation sheet, and start() will report the real
      // failure.
      granted = false;
    }
    if (granted) return true;
    if (!mounted) return false;

    final AikoL10n l10n = context.l10n;
    return showAikoConfirmSheet(
      context,
      title: l10n.t('vpn.permission.title'),
      message: l10n.t('vpn.permission.message'),
      confirmLabel: l10n.t('common.continue'),
      cancelLabel: l10n.t('common.cancel'),
      icon: Icons.vpn_lock_rounded,
    );
  }
}
