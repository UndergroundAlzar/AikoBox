/// Listens for `clash://` / `mihomo://` / `aikobox://install-config` links and
/// turns them into a *question*, never into an import.
///
/// Port of `src/main/deeplink.ts` + `src/main/confirmSubscriptionImport.ts`.
/// The desktop gate is a native message box whose default button is Cancel;
/// here it is a modal sheet that returns false unless Import is pressed, which
/// makes dismissing it — swipe, scrim tap, back gesture — the same as Cancel.
///
/// Three properties are load-bearing and are the reason this is not three
/// lines inside `main()`:
///
/// * **Never auto-import.** Any web page can fire a deep link. A subscription
///   is executable configuration; installing one without a prompt is remote
///   code delivery.
/// * **Show the hostname, nothing else.** Subscription tokens live in the
///   query string. The sheet renders `profiles.deepLink.message` with the
///   host substituted and the URL never leaves this file (N7).
/// * **Never echo the link in an error.** Every failure path resolves to a
///   fixed localised string with no interpolation of anything link-derived.
library;

import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../l10n/aiko_l10n.dart';
import '../../widgets/widgets.dart';
import 'deep_link_parser.dart';
import 'shell_destination.dart';
import 'shell_snackbar.dart';

/// Two deliveries of the same link inside this window are treated as one.
///
/// On a cold start Android hands the launch intent to both `getInitialLink()`
/// and the link stream, and the user should be asked once.
const Duration kDeepLinkDedupeWindow = Duration(seconds: 3);

/// Wraps the app and processes incoming links.
///
/// Mount it inside `MaterialApp.builder` so its context sits below the
/// `Navigator`, the `ScaffoldMessenger` and `Localizations` — the sheet, the
/// snackbars and `AikoL10n.of` all need that.
class DeepLinkListener extends ConsumerStatefulWidget {
  const DeepLinkListener({super.key, required this.child, this.links});

  final Widget child;

  /// Injectable for tests. Defaults to the `app_links` singleton.
  final AppLinks? links;

  @override
  ConsumerState<DeepLinkListener> createState() => _DeepLinkListenerState();
}

class _DeepLinkListenerState extends ConsumerState<DeepLinkListener> {
  StreamSubscription<String>? _subscription;
  bool _busy = false;
  String? _lastLink;
  DateTime? _lastLinkAt;

  @override
  void initState() {
    super.initState();
    final AppLinks links = widget.links ?? AppLinks();
    _subscription = links.stringLinkStream.listen(
      _handle,
      onError: (Object error) {
        // A malformed intent extra must not take the app down, and the error
        // object can contain the link, so it is not printed.
        debugPrint('deep link stream error: ${error.runtimeType}');
      },
    );
    unawaited(_consumeLaunchLink(links));
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  Future<void> _consumeLaunchLink(AppLinks links) async {
    try {
      final String? initial = await links.getInitialLinkString();
      if (initial != null) await _handle(initial);
    } catch (error) {
      debugPrint('initial deep link unreadable: ${error.runtimeType}');
    }
  }

  bool _isDuplicate(String raw) {
    final DateTime now = DateTime.now();
    final DateTime? previousAt = _lastLinkAt;
    if (_lastLink == raw &&
        previousAt != null &&
        now.difference(previousAt) < kDeepLinkDedupeWindow) {
      // Deliberately does not refresh the timestamp: the window is measured
      // from the accepted delivery, so a user who taps the same link again a
      // few seconds later is asked again rather than silently ignored.
      return true;
    }
    _lastLink = raw;
    _lastLinkAt = now;
    return false;
  }

  Future<void> _handle(String raw) async {
    final DeepLinkResult result = parseAikoDeepLinkString(raw);
    if (result is DeepLinkIgnored) return;
    if (_busy || _isDuplicate(raw)) return;
    if (!mounted) return;

    _busy = true;
    try {
      // Wait for the first frame on a cold start, otherwise there is no
      // Navigator to put the sheet into yet.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;

      switch (result) {
        case DeepLinkIgnored():
          return;
        case DeepLinkRejected(:final reason):
          showAikoSnackBar(
            context,
            deepLinkRejectionMessage(AikoL10n.of(context), reason),
          );
        case final DeepLinkSubscription subscription:
          await _confirmAndImport(subscription);
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _confirmAndImport(DeepLinkSubscription request) async {
    final AikoL10n l10n = AikoL10n.of(context);

    final bool confirmed = await showAikoConfirmSheet(
      context,
      title: l10n.t('profiles.deepLink.title'),
      // The host, and only the host. Not the path, not the query.
      message: l10n.t(
        'profiles.deepLink.message',
        args: <String, Object?>{'host': request.host},
      ),
      confirmLabel: l10n.t('profiles.import'),
      cancelLabel: l10n.t('common.cancel'),
      icon: Icons.link_rounded,
    );
    if (!confirmed) return;
    if (!mounted) return;

    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(
      context,
    );
    messenger?.showSnackBar(
      SnackBar(
        duration: const Duration(minutes: 5),
        content: Row(
          children: <Widget>[
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(l10n.t('profiles.updating'))),
          ],
        ),
      ),
    );

    try {
      await ref
          .read(profilesProvider.notifier)
          .importRemote(url: request.url.toString(), name: request.name);
      messenger?.hideCurrentSnackBar();
      if (!mounted) return;
      showAikoSnackBar(context, l10n.t('profiles.notification.importSuccess'));
      ref.read(shellTabProvider.notifier).select(kShellProfilesTab);
    } catch (error) {
      // `error` can be a SubscriptionException whose message the core layer
      // has already redacted, but it can also be an HTTP client error that
      // stringifies the whole URL. Neither is worth the risk: the fixed
      // string says what happened without quoting anything.
      debugPrint('deep-link import failed: ${error.runtimeType}');
      messenger?.hideCurrentSnackBar();
      if (!mounted) return;
      showAikoSnackBar(context, l10n.t('profiles.error.importFailed'));
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Maps a refusal onto a display string.
///
/// Specific keys are used when the locale bundle has them and the generic
/// import-failure string otherwise, so adding
/// `profiles.deepLink.error.malformed` / `.insecureTarget` to the locale files
/// improves the message with no code change. Every candidate is a fixed
/// sentence — none of them interpolates anything derived from the link.
String deepLinkRejectionMessage(AikoL10n l10n, DeepLinkRejection reason) {
  final String preferred = switch (reason) {
    DeepLinkRejection.malformed => 'profiles.deepLink.error.malformed',
    DeepLinkRejection.missingUrl => 'profiles.error.urlParamMissing',
    DeepLinkRejection.insecureTarget =>
      'profiles.deepLink.error.insecureTarget',
  };
  if (l10n.has(preferred)) return l10n.t(preferred);
  return l10n.t('profiles.error.importFailed');
}
