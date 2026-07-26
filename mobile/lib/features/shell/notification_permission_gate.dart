/// Asks for `POST_NOTIFICATIONS` the first time the tunnel is brought up.
///
/// Android 13+ will not show the ongoing VPN notification without it, and
/// Android requires a foreground service notification while a VPN runs — so
/// without the permission the tunnel works but is invisible, which for a
/// traffic interceptor is the wrong kind of quiet.
///
/// This watches [coreStatusProvider] rather than hanging off whatever widget
/// happens to start the tunnel. The FAB is not the only route in: a tile, a
/// notification action, an always-on VPN restart or a deep link could all
/// bring the core up, and the prompt has to be tied to the event, not to one
/// button. Asking here also means the request lands *after* the user has
/// already agreed to the VPN, which is the point at which "AikoBox wants to
/// show you a notification" makes obvious sense.
///
/// It fires at most once per install (see [kNotificationRationaleShownKey])
/// and never blocks the start.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import 'shell_providers.dart';

class NotificationPermissionGate extends ConsumerStatefulWidget {
  const NotificationPermissionGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<NotificationPermissionGate> createState() =>
      _NotificationPermissionGateState();
}

class _NotificationPermissionGateState
    extends ConsumerState<NotificationPermissionGate> {
  bool _offeredThisSession = false;

  @override
  Widget build(BuildContext context) {
    ref.listen<CoreStatus>(coreStatusProvider, (
      CoreStatus? previous,
      CoreStatus next,
    ) {
      // `starting` is the first state that means "the user asked for a
      // tunnel". Waiting for `running` would put the prompt on top of a
      // health-gate failure.
      final bool becameActive =
          next.state.isActive && !(previous?.state.isActive ?? false);
      if (!becameActive || _offeredThisSession) return;
      _offeredThisSession = true;
      unawaited(_offer());
    });

    return widget.child;
  }

  Future<void> _offer() async {
    // One frame of headroom so the prompt does not race the sheet the start
    // button may still be dismissing.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    await ref
        .read(vpnPermissionFlowProvider)
        .offerNotificationPermission(context);
  }
}
