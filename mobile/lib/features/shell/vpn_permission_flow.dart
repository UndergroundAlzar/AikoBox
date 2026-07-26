/// The consent choreography that runs before the tunnel is allowed to come up.
///
/// Two separate Android permissions are in play and they are not equivalent:
///
/// * **VPN consent** (`VpnService.prepare`) is mandatory — without it there is
///   no tunnel at all. `AikoCoreController.start` already asks for it, but it
///   asks from a background call with no UI, which means the system dialog
///   lands on the user with no explanation of why an app they just opened
///   wants to intercept all their traffic. This flow puts an explanation in
///   front of it and gives "no" a first-class answer, so a refusal is a
///   decision rather than a failed start.
/// * **`POST_NOTIFICATIONS`** (Android 13+) is optional — the tunnel runs
///   fine without it, the user just cannot see the ongoing notification.
///   It is therefore asked for *once*, never blocks, and never re-prompts.
///
/// This file holds no Riverpod wiring on purpose: it depends only on the
/// [CoreChannel] interface and [ShellHostChannel], so it can be driven from a
/// widget test with fakes. `shell_providers.dart` does the wiring.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/core_channel.dart';
import '../../l10n/aiko_l10n.dart';
import '../../widgets/widgets.dart';
import 'shell_host_channel.dart';
import 'shell_snackbar.dart';

/// Outcome of [VpnPermissionFlow.ensureReady].
enum TunnelPermissionResult {
  /// VPN consent is held. The caller may start the core.
  ready,

  /// The system dialog was shown and refused. The user has been told what
  /// that means; do not start, and do not ask again unprompted.
  vpnDeclined,

  /// The user backed out of the explanation before the system dialog. Say
  /// nothing further — they already know what they did.
  cancelled,
}

/// shared_preferences key for "we have shown the notification rationale".
///
/// Android itself stops showing the `POST_NOTIFICATIONS` dialog after two
/// dismissals; this makes sure AikoBox stops after one, because the tunnel
/// works either way and a prompt on every start would be noise.
const String kNotificationRationaleShownKey = 'aiko.shell.notificationAsked';

/// Runs the pre-start permission checks.
class VpnPermissionFlow {
  VpnPermissionFlow({
    required CoreChannel channel,
    required ShellHostChannel host,
    Future<SharedPreferences> Function()? preferences,
  }) : _channel = channel,
       _host = host,
       _preferences = preferences ?? SharedPreferences.getInstance;

  final CoreChannel _channel;
  final ShellHostChannel _host;
  final Future<SharedPreferences> Function() _preferences;

  /// Ensures VPN consent, then offers the notification prompt.
  ///
  /// Returns [TunnelPermissionResult.ready] when the caller may proceed to
  /// `CoreController.start()`. The core re-checks consent itself; this is the
  /// explained path to the same answer, not a replacement for it.
  Future<TunnelPermissionResult> ensureReady(BuildContext context) async {
    final AikoL10n l10n = AikoL10n.of(context);

    final bool? alreadyGranted = await _prepareVpn();
    if (!context.mounted) return TunnelPermissionResult.cancelled;

    // null means the host could not answer — a debug pairing against a build
    // without the Kotlin side. Let the controller produce the real error
    // rather than inventing a permission story here.
    if (alreadyGranted == false) {
      final bool proceed = await showAikoConfirmSheet(
        context,
        title: l10n.t('vpn.permission.title'),
        message: l10n.t('vpn.permission.message'),
        confirmLabel: l10n.t('common.continue'),
        cancelLabel: l10n.t('common.cancel'),
        icon: Icons.vpn_key_rounded,
      );
      if (!proceed) return TunnelPermissionResult.cancelled;

      final bool accepted = await _requestVpn();
      if (!context.mounted) return TunnelPermissionResult.vpnDeclined;
      if (!accepted) {
        await showVpnPermissionDenied(context);
        return TunnelPermissionResult.vpnDeclined;
      }
    }

    if (!context.mounted) return TunnelPermissionResult.ready;
    await offerNotificationPermission(context);
    return TunnelPermissionResult.ready;
  }

  /// Explains a refused — or revoked — VPN grant, and offers the system VPN
  /// settings page when the host can open it.
  ///
  /// Also the right thing to show when a start fails with
  /// `CoreStartException.codeVpnPermissionDenied`.
  Future<void> showVpnPermissionDenied(BuildContext context) async {
    final AikoL10n l10n = AikoL10n.of(context);
    if (!_host.isAvailable) {
      await showAikoConfirmSheet(
        context,
        title: l10n.t('vpn.permission.denied.title'),
        message: l10n.t('vpn.permission.denied.message'),
        confirmLabel: l10n.t('common.ok'),
        cancelLabel: l10n.t('common.dismiss'),
        icon: Icons.gpp_bad_rounded,
        destructive: true,
      );
      return;
    }

    final bool openSettings = await showAikoConfirmSheet(
      context,
      title: l10n.t('vpn.permission.denied.title'),
      message: l10n.t('vpn.permission.denied.message'),
      confirmLabel: l10n.t('vpn.permission.openSettings'),
      cancelLabel: l10n.t('common.dismiss'),
      icon: Icons.gpp_bad_rounded,
    );
    if (openSettings) await _host.openVpnSettings();
  }

  /// Offers the Android 13+ `POST_NOTIFICATIONS` prompt, at most once ever.
  ///
  /// Never blocks, never returns a failure: the tunnel runs without the
  /// permission, the user just cannot see its status. Safe to call at any
  /// point where a sheet may legally appear.
  Future<void> offerNotificationPermission(BuildContext context) async {
    final AikoL10n l10n = AikoL10n.of(context);
    final NotificationPermission status = await _host
        .notificationPermissionStatus();
    if (!context.mounted) return;

    switch (status) {
      case NotificationPermission.granted:
      case NotificationPermission.unsupported:
        return;

      case NotificationPermission.permanentlyDenied:
        // The dialog is dead; nagging with a sheet the user cannot act on
        // would be worse than a dismissible line with a way out.
        showAikoSnackBar(
          context,
          l10n.t('notification.permission.denied'),
          actionLabel: l10n.t('notification.settings'),
          onAction: () => unawaited(_host.openNotificationSettings()),
        );
        return;

      case NotificationPermission.denied:
        if (await _rationaleAlreadyShown()) return;
        if (!context.mounted) return;
        final bool ask = await showAikoConfirmSheet(
          context,
          title: l10n.t('notification.permission.title'),
          message: l10n.t('notification.permission.message'),
          confirmLabel: l10n.t('common.allow'),
          cancelLabel: l10n.t('common.notNow'),
          icon: Icons.notifications_active_rounded,
        );
        await _markRationaleShown();
        if (!ask) return;

        final bool granted = await _host.requestNotificationPermission();
        if (granted || !context.mounted) return;
        showAikoSnackBar(context, l10n.t('notification.permission.denied'));
    }
  }

  /// `prepareVpn`, mapped to tri-state: true granted, false not yet,
  /// null the host could not be asked.
  Future<bool?> _prepareVpn() async {
    try {
      return await _channel.prepareVpn();
    } on AikoCoreException catch (error) {
      debugPrint('prepareVpn unavailable: ${error.code}');
      return null;
    }
  }

  Future<bool> _requestVpn() async {
    try {
      return await _channel.requestVpnPermission();
    } on AikoCoreException catch (error) {
      debugPrint('requestVpnPermission failed: ${error.code}');
      return false;
    }
  }

  Future<bool> _rationaleAlreadyShown() async {
    try {
      final SharedPreferences prefs = await _preferences();
      return prefs.getBool(kNotificationRationaleShownKey) ?? false;
    } catch (error) {
      debugPrint('notification rationale flag unreadable: $error');
      // Unreadable preferences must not turn into a prompt loop.
      return true;
    }
  }

  Future<void> _markRationaleShown() async {
    try {
      final SharedPreferences prefs = await _preferences();
      await prefs.setBool(kNotificationRationaleShownKey, true);
    } catch (error) {
      debugPrint('notification rationale flag unwritable: $error');
    }
  }
}
