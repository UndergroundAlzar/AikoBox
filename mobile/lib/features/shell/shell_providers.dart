/// Riverpod wiring for the shell's permission flow.
///
/// Kept apart from `vpn_permission_flow.dart` so that file depends only on the
/// `CoreChannel` interface and stays drivable from a widget test with fakes.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import 'shell_host_channel.dart';
import 'vpn_permission_flow.dart';

final Provider<VpnPermissionFlow> vpnPermissionFlowProvider =
    Provider<VpnPermissionFlow>(
      (Ref ref) => VpnPermissionFlow(
        channel: ref.watch(coreChannelProvider),
        host: ref.watch(shellHostChannelProvider),
      ),
    );

/// The whole pre-start preflight: explain, ask for VPN consent, then offer the
/// notification prompt.
///
/// Returns true when consent is held and the caller should proceed to
/// `ref.read(coreControllerProvider).start()`. Returns false when the user
/// declined or backed out — they have already been told what happened and the
/// caller should do nothing further.
///
/// Skipping it is not a correctness bug — `AikoCoreController.start` asks for
/// consent itself, and `NotificationPermissionGate` covers the notification
/// half from the shell — but a caller that owns a start button should prefer
/// this over reimplementing the explanation.
Future<bool> ensureTunnelPermissions(
  BuildContext context,
  WidgetRef ref,
) async {
  final TunnelPermissionResult result = await ref
      .read(vpnPermissionFlowProvider)
      .ensureReady(context);
  return result == TunnelPermissionResult.ready;
}
