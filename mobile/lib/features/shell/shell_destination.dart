/// The shell's destination model and the selected-tab state.
///
/// Kept free of every feature import so [HomeShell] can be built and tested
/// against synthetic destinations. The concrete four-destination list lives in
/// `shell_pages.dart`, which is the single file that knows the feature widgets
/// exist.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Stable destination ids. Anything that wants to navigate the shell does so
/// by id — `ref.read(shellTabProvider.notifier).select(kShellProfilesTab)` —
/// so nothing outside the shell has to know the bar's ordering.
const String kShellDashboardTab = 'dashboard';
const String kShellProxiesTab = 'proxies';
const String kShellProfilesTab = 'profiles';
const String kShellToolsTab = 'tools';

/// One entry in the bottom `NavigationBar` / side `NavigationRail`.
@immutable
class ShellDestination {
  const ShellDestination({
    required this.id,
    required this.labelKey,
    required this.icon,
    required this.selectedIcon,
    required this.builder,
  });

  /// Stable identity, independent of position. Persisted nowhere, but used by
  /// deep links and by the Tools page to jump between sections.
  final String id;

  /// l10n key — `nav.dashboard`, `nav.proxies`, … Resolved by the shell, never
  /// by the caller, so a destination list contains no display strings.
  final String labelKey;

  /// Outline glyph, shown when the destination is not selected.
  final IconData icon;

  /// Filled glyph, shown inside the selection indicator.
  final IconData selectedIcon;

  /// Builds the page. Called lazily by the `PageView`.
  final WidgetBuilder builder;

  @override
  String toString() => 'ShellDestination($id)';
}

/// Which destination the shell is showing, by [ShellDestination.id].
///
/// Holding the id rather than an index means a caller never has to guess the
/// bar's order, and an id that is not currently on the bar resolves to the
/// first destination instead of throwing or showing a blank page.
class ShellTabNotifier extends Notifier<String> {
  @override
  String build() => kShellDashboardTab;

  /// Switches to [id]. A no-op when it is already selected, so this is safe to
  /// call from a rebuild-heavy callback.
  void select(String id) {
    if (id.isEmpty || state == id) return;
    state = id;
  }
}

final NotifierProvider<ShellTabNotifier, String> shellTabProvider =
    NotifierProvider<ShellTabNotifier, String>(ShellTabNotifier.new);
