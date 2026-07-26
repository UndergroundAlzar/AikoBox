/// How a dashboard card asks the app shell to open another screen.
///
/// The dashboard deliberately knows nothing about the router. On the desktop
/// every sider card was a `navigate('/rules')`; here the shell owns navigation
/// — two of the destinations are sibling pages inside the bottom-bar
/// `PageView`, the rest are pushed routes — so the dashboard publishes an
/// intent and lets the shell decide what that means.
///
/// Wire it once, where the shell is built:
///
/// ```dart
/// ProviderScope(
///   overrides: <Override>[
///     dashboardNavigateProvider.overrideWithValue((destination) {
///       switch (destination) {
///         case DashboardDestination.proxies:
///           pageController.jumpToPage(1);
///         case DashboardDestination.profiles:
///           pageController.jumpToPage(2);
///         default:
///           Navigator.of(context).pushNamed(destination.routeName);
///       }
///     }),
///   ],
///   child: const AikoApp(),
/// )
/// ```
///
/// Left unwired, cards whose only job is navigation simply stop being
/// tappable. They still render their counts and toggles — nothing turns into a
/// dead button that looks live.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Screens a dashboard card can send the user to.
enum DashboardDestination {
  /// Proxy groups and nodes.
  proxies('/proxies'),

  /// Subscription / profile management.
  profiles('/profiles'),

  /// Live connection list.
  connections('/connections'),

  /// Real-time core log.
  logs('/logs'),

  /// The active rule list.
  rules('/rules'),

  /// Proxy and rule providers.
  resources('/resources'),

  /// DNS settings.
  dns('/dns'),

  /// Domain-sniffing settings.
  sniffer('/sniffer'),

  /// Core settings (log level, ports, delay test).
  coreSettings('/core'),

  /// Network information — IP, location, latency.
  networkInfo('/network'),

  /// Cumulative traffic statistics.
  trafficStats('/traffic');

  const DashboardDestination(this.routeName);

  /// A conventional route name, offered so a shell that uses a route table can
  /// forward straight to it. Nothing in this feature reads it.
  final String routeName;
}

/// The callback the shell installs so cards can navigate.
typedef DashboardNavigate = void Function(DashboardDestination destination);

/// The shell's navigation callback, or `null` when nothing has been wired.
///
/// Override it at the `ProviderScope` that hosts the app shell.
final Provider<DashboardNavigate?> dashboardNavigateProvider =
    Provider<DashboardNavigate?>((Ref ref) => null);
