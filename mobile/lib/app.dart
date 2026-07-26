/// The `MaterialApp` and everything that has to sit above every screen:
/// theme, locale, reading direction, text-scale bounds and the deep-link gate.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/dashboard/dashboard_navigation.dart';
import 'features/shell/deep_link_handler.dart';
import 'features/shell/home_shell.dart';
import 'features/shell/notification_permission_gate.dart';
import 'features/shell/shell_destination.dart';
import 'features/shell/shell_pages.dart';
import 'l10n/aiko_l10n.dart';
import 'theme/theme.dart';

/// Below 0.8 the delay chips stop being readable; above 1.4 the dashboard
/// cards, whose heights are computed from line counts, start clipping. The
/// brief fixes the same range for the in-app text-scale slider.
const double kMinTextScale = 0.8;
const double kMaxTextScale = 1.4;

class AikoApp extends ConsumerWidget {
  const AikoApp({super.key, this.destinations});

  /// Overridable so a test can mount the real shell over stub pages.
  /// Defaults to the contract's four.
  final List<ShellDestination>? destinations;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeMode themeMode = ref.watch(themeModeProvider);
    final ThemeData light = ref.watch(lightThemeProvider);
    final ThemeData dark = ref.watch(darkThemeProvider);
    final Locale? locale = ref.watch(activeLocaleProvider);

    return MaterialApp(
      // The window title is Android's task-switcher label; it is set from the
      // locale bundle once localisations resolve.
      title: 'AikoBox',
      onGenerateTitle: (BuildContext context) => context.tr('app.name'),
      debugShowCheckedModeBanner: false,

      theme: light,
      darkTheme: dark,
      themeMode: themeMode,

      locale: locale,
      supportedLocales: AikoL10n.supportedLocales,
      localizationsDelegates: AikoL10n.localizationsDelegates,
      localeListResolutionCallback: resolveAikoLocale,

      builder: _buildAppLayer,
      // `dashboardNavigateProvider` is wired at the root scope in `main.dart`
      // — see [dashboardNavigateFor]. Doing it there rather than in a nested
      // `ProviderScope` here keeps one container for the whole app, so the
      // deep-link listener (which lives above `home`) and the shell (below it)
      // provably share the same `shellTabProvider` instance.
      home: HomeShell(destinations: destinations ?? kAikoShellDestinations),
    );
  }

  /// Wraps everything below the `Navigator`.
  ///
  /// The deep-link listener and the notification gate live here rather than in
  /// `main()` because both have to be able to open a modal sheet, which needs
  /// a `Navigator`, an `Overlay`, a `ScaffoldMessenger` and resolved
  /// localisations — all of which exist at exactly this point in the tree and
  /// nowhere above it.
  static Widget _buildAppLayer(BuildContext context, Widget? child) {
    final MediaQueryData media = MediaQuery.of(context);
    final Widget content = DeepLinkListener(
      child: NotificationPermissionGate(
        child: child ?? const SizedBox.shrink(),
      ),
    );

    return MediaQuery(
      data: media.copyWith(
        textScaler: media.textScaler.clamp(
          minScaleFactor: kMinTextScale,
          maxScaleFactor: kMaxTextScale,
        ),
      ),
      // `Localizations` already installs a `Directionality` from
      // `GlobalWidgetsLocalizations`. This restates it from AikoBox's own
      // locale table so the app cannot end up left-to-right under `fa-IR`
      // because Material resolved the locale differently than we did.
      child: Directionality(
        textDirection:
            AikoL10n.maybeOf(context)?.textDirection ??
            Directionality.of(context),
        child: content,
      ),
    );
  }
}

/// Picks the shipped locale closest to the device's preference list.
///
/// Flutter's default resolution matches on `languageCode` first and would
/// answer `zh-Hant` with `zh-CN`; [AikoL10n.resolveTag] knows that Traditional
/// script belongs with `zh-TW`. Unknown languages fall through to the next
/// preference rather than immediately landing on English.
Locale resolveAikoLocale(List<Locale>? preferred, Iterable<Locale> supported) {
  for (final Locale candidate in preferred ?? const <Locale>[]) {
    final AikoLocaleInfo info = AikoL10n.infoForLocale(candidate);
    // resolveTag falls back to en-US for anything unrecognised; only accept
    // the answer when it really is the same language.
    if (info.languageCode == candidate.languageCode.toLowerCase()) {
      return info.locale;
    }
  }
  return AikoL10n.infoForTag(kBaseLocaleTag).locale;
}

/// The shell's implementation of [DashboardNavigate].
///
/// The dashboard publishes navigation intents and lets the shell decide what
/// they mean (see `features/dashboard/dashboard_navigation.dart`). Install it
/// with `dashboardNavigateProvider.overrideWith(dashboardNavigateFor)`.
DashboardNavigate dashboardNavigateFor(Ref ref) {
  return (DashboardDestination destination) {
    ref
        .read(shellTabProvider.notifier)
        .select(shellTabForDashboardDestination(destination));
  };
}

/// Maps a dashboard navigation intent onto a shell tab id.
String shellTabForDashboardDestination(DashboardDestination destination) {
  return switch (destination) {
    DashboardDestination.proxies => kShellProxiesTab,
    DashboardDestination.profiles => kShellProfilesTab,
    // Connections, Logs, Rules, DNS, Sniffer, Resources, Traffic, Network and
    // Core settings are all reached from the Tools page on a phone (brief
    // §4.1: whatever is not on the bar lives under the Tools page's More
    // section).
    _ => kShellToolsTab,
  };
}
