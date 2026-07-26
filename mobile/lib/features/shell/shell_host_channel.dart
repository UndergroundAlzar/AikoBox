/// A narrow platform channel for the two things the shell needs from Android
/// that `aikobox/core` (§4.4) deliberately does not cover.
///
/// `aikobox/core` is the tunnel's channel: consent, start, stop, config check.
/// Runtime permission plumbing and "open the system settings page" are UI
/// concerns, so they live here instead of widening a contract that both the
/// core agent and the Kotlin agent code against.
///
/// **Kotlin side — the contract this file expects:**
///
/// ```
/// MethodChannel "aikobox/shell"
///   notificationPermissionStatus() -> String
///        "granted"            POST_NOTIFICATIONS held, or SDK < 33
///        "denied"             not held, the system dialog would still show
///        "permanentlyDenied"  not held and shouldShowRequestPermissionRationale
///                             is false after at least one ask — the dialog is
///                             dead, only Settings can change it
///        "unsupported"        no notification permission model on this build
///   requestNotificationPermission() -> bool    // resolves after the dialog closes
///   openNotificationSettings()      -> bool    // ACTION_APP_NOTIFICATION_SETTINGS
///   openVpnSettings()               -> bool    // Settings.ACTION_VPN_SETTINGS
/// ```
///
/// Every method degrades: until the host implements the channel, Flutter
/// raises `MissingPluginException`, this class latches [isAvailable] to false,
/// and the shell simply skips the notification prompt and hides the
/// open-settings affordances. Nothing breaks and nothing is faked.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The Android 13+ `POST_NOTIFICATIONS` state, as far as the shell cares.
enum NotificationPermission {
  granted,
  denied,

  /// Asking again would do nothing; only the system settings page can help.
  permanentlyDenied,

  /// No runtime notification permission on this platform or build.
  unsupported;

  static NotificationPermission fromWire(Object? raw) {
    return switch (raw?.toString()) {
      'granted' => NotificationPermission.granted,
      'denied' => NotificationPermission.denied,
      'permanentlyDenied' => NotificationPermission.permanentlyDenied,
      _ => NotificationPermission.unsupported,
    };
  }
}

/// Client for `MethodChannel("aikobox/shell")`.
class ShellHostChannel {
  ShellHostChannel({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'aikobox/shell';

  final MethodChannel _channel;

  bool _unavailable = false;

  /// False once a call has come back as `MissingPluginException`. The shell
  /// uses this to stop offering affordances the host cannot honour.
  bool get isAvailable => !_unavailable;

  Future<NotificationPermission> notificationPermissionStatus() async {
    final Object? raw = await _call<Object>('notificationPermissionStatus');
    if (raw == null) return NotificationPermission.unsupported;
    return NotificationPermission.fromWire(raw);
  }

  /// Shows the system permission dialog. Resolves to the user's answer, or
  /// false when the host cannot ask.
  Future<bool> requestNotificationPermission() async =>
      await _call<bool>('requestNotificationPermission') ?? false;

  /// Opens this app's notification settings. False when it could not be shown.
  Future<bool> openNotificationSettings() async =>
      await _call<bool>('openNotificationSettings') ?? false;

  /// Opens the system VPN settings page, where a revoked or always-on VPN
  /// grant is managed. False when it could not be shown.
  Future<bool> openVpnSettings() async =>
      await _call<bool>('openVpnSettings') ?? false;

  Future<T?> _call<T>(String method) async {
    if (_unavailable) return null;
    try {
      return await _channel.invokeMethod<T>(method);
    } on MissingPluginException {
      // Latched, so a channel-less build does one failed lookup per method
      // rather than one per prompt.
      _unavailable = true;
      return null;
    } on PlatformException catch (error) {
      debugPrint('aikobox/shell.$method failed: ${error.code}');
      return null;
    }
  }
}

final Provider<ShellHostChannel> shellHostChannelProvider =
    Provider<ShellHostChannel>((Ref ref) => ShellHostChannel());
