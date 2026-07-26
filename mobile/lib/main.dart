/// AikoBox for Android — entry point.
///
/// The job here is to get the three things that decide what the *first* frame
/// looks like off disk before that frame is built: the chosen language, the
/// chosen theme, and the application directories. Each is read behind its own
/// guard, because none of them is worth failing to launch over — a phone with
/// an unreadable preference store should still open to a usable app in the
/// system language with the default palette.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/providers.dart';
import 'features/dashboard/dashboard_navigation.dart';
import 'l10n/aiko_l10n.dart';
import 'theme/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _installErrorHandlers();

  // Android 15 draws behind the bars whether or not we ask, so ask, and let
  // the per-page `SafeArea`s do the insetting.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  // Independent, all I/O-bound, so they overlap. Each resolves to a usable
  // value even when its own read fails.
  final Future<AikoThemeSettings> themeFuture = _guard(
    'theme settings',
    ThemeController.loadPersisted,
    AikoThemeSettings.defaults,
  );
  final Future<void> localeFuture = _guardVoid(
    'locale bundles',
    AikoL10n.ensureInitialized,
  );
  final Future<void> coreFuture = _guardVoid(
    'core directories',
    bootstrapAikoCore,
  );

  final AikoThemeSettings themeSettings = await themeFuture;
  await localeFuture;
  await coreFuture;

  runApp(
    ProviderScope(
      overrides: [
        // Hands the controller its persisted value synchronously, so the app
        // never paints one frame of the default palette before correcting
        // itself.
        preloadedThemeSettingsProvider.overrideWithValue(themeSettings),
        // Lets dashboard cards navigate. Wired here, at the single root
        // container, so every layer of the app shares one shell-tab notifier.
        dashboardNavigateProvider.overrideWith(dashboardNavigateFor),
      ],
      child: const AikoApp(),
    ),
  );
}

/// Runs [task], returning [fallback] if it throws.
Future<T> _guard<T>(String what, Future<T> Function() task, T fallback) async {
  try {
    return await task();
  } catch (error, stack) {
    debugPrint('AikoBox: could not load $what: $error');
    debugPrintStack(stackTrace: stack);
    return fallback;
  }
}

Future<void> _guardVoid(String what, Future<void> Function() task) async {
  try {
    await task();
  } catch (error, stack) {
    debugPrint('AikoBox: could not initialise $what: $error');
    debugPrintStack(stackTrace: stack);
  }
}

void _installErrorHandlers() {
  // A dropped websocket frame or a failed delay probe must not take down a
  // VPN client that is, at that moment, carrying the user's traffic. In debug
  // the error still surfaces so it gets fixed.
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    debugPrint('AikoBox: uncaught async error: $error');
    debugPrintStack(stackTrace: stack);
    return kReleaseMode;
  };

  if (kReleaseMode) {
    // The red error screen is a debugging tool. In a shipped build a widget
    // that failed to build should leave a quiet gap, not a wall of stack
    // trace over the top of a running tunnel. No text: there is no
    // `BuildContext` here, so there is no way to localise one (rule §2.6).
    ErrorWidget.builder = (FlutterErrorDetails details) =>
        const _QuietErrorPlaceholder();
  }
}

class _QuietErrorPlaceholder extends StatelessWidget {
  const _QuietErrorPlaceholder();

  @override
  Widget build(BuildContext context) {
    // An error widget can be inserted anywhere, including above the app's own
    // `Directionality`, so it supplies its own. The glyph is symmetric.
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Icon(
            Icons.error_outline_rounded,
            size: 20,
            color: Theme.of(context).colorScheme.error.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }
}
