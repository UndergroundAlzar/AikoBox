/// One place for the shell's transient messages.
///
/// Material's `SnackBar` already wraps its content in
/// `Semantics(liveRegion: true)`, so TalkBack reads it without an explicit
/// announcement — which matters, because `SemanticsService.announce` is
/// deprecated and Android itself deprecated the underlying
/// `announceForAccessibility` event. Brief §4.5 requires toasts to be
/// announced; a live region is how that is done now.
library;

import 'package:flutter/material.dart';

/// Shows [message], replacing anything currently on screen.
///
/// A no-op when there is no `ScaffoldMessenger` above [context] — which
/// happens during teardown and in tests that pump a bare widget.
void showAikoSnackBar(
  BuildContext context,
  String message, {
  String? actionLabel,
  VoidCallback? onAction,
  Duration duration = const Duration(seconds: 5),
}) {
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        duration: duration,
        action: actionLabel == null || onAction == null
            ? null
            : SnackBarAction(label: actionLabel, onPressed: onAction),
      ),
    );
}
