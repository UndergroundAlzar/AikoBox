/// The concrete four destinations, and the only file in the shell that knows
/// the feature packages exist.
///
/// Everything else in `features/shell/` is written against
/// [ShellDestination], so the shell can be built and tested without any
/// feature code, and a rename on the feature side is a one-line change here
/// rather than a change to the navigation.
///
/// Order is the bar order and is fixed by contract §6:
/// Dashboard · Proxies · Profiles · Tools.
library;

import 'package:flutter/material.dart';

import '../dashboard/dashboard_page.dart';
import '../profiles/profiles_page.dart';
import '../proxies/proxies_page.dart';
import '../tools/tools_page.dart';
import 'shell_destination.dart';

/// The bottom bar / rail, in order.
final List<ShellDestination> kAikoShellDestinations = <ShellDestination>[
  ShellDestination(
    id: kShellDashboardTab,
    labelKey: 'nav.dashboard',
    icon: Icons.space_dashboard_outlined,
    selectedIcon: Icons.space_dashboard,
    builder: (BuildContext context) => const DashboardPage(),
  ),
  ShellDestination(
    id: kShellProxiesTab,
    labelKey: 'nav.proxies',
    icon: Icons.article_outlined,
    selectedIcon: Icons.article,
    builder: (BuildContext context) => const ProxiesPage(),
  ),
  ShellDestination(
    id: kShellProfilesTab,
    labelKey: 'nav.profiles',
    icon: Icons.folder_outlined,
    selectedIcon: Icons.folder,
    builder: (BuildContext context) => const ProfilesPage(),
  ),
  ShellDestination(
    id: kShellToolsTab,
    labelKey: 'nav.tools',
    icon: Icons.construction_outlined,
    selectedIcon: Icons.construction,
    builder: (BuildContext context) => const ToolsPage(),
  ),
];
