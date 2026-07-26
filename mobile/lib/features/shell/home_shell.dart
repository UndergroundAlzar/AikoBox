/// The adaptive four-destination shell (contract §6, brief §4.1).
///
/// Bottom `NavigationBar` below 600 dp, side `NavigationRail` above it, with
/// the pages hosted in a `PageView` whose physics are disabled — swiping
/// between a proxy grid and a log list is never what the user meant.
///
/// The bar is a sibling of the page area inside a `Column`, not
/// `Scaffold.bottomNavigationBar`, so the bottom system inset can be handed to
/// the bar alone and the pages can lay out against a clean edge. Pages bring
/// their own `AikoScaffold`, which is what keeps the large plain title, the
/// FAB and any page-level actions with the page rather than with the shell.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/aiko_l10n.dart';
import '../../theme/app_theme.dart';
import 'shell_destination.dart';

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key, required this.destinations});

  /// Must not be empty. Order is the bar order.
  final List<ShellDestination> destinations;

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  late final PageController _controller;
  late int _index;

  @override
  void initState() {
    super.initState();
    assert(
      widget.destinations.isNotEmpty,
      'HomeShell needs at least one destination',
    );
    _index = _indexOf(ref.read(shellTabProvider));
    _controller = PageController(initialPage: _index);
  }

  @override
  void didUpdateWidget(covariant HomeShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The destination list is effectively constant, but a hot reload or a
    // future "hide Proxies when there are no groups" rule can shorten it out
    // from under a selection that is now past the end.
    final int clamped = _indexOf(ref.read(shellTabProvider));
    if (clamped != _index) _jump(clamped);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int _indexOf(String id) {
    final int found = widget.destinations.indexWhere(
      (ShellDestination d) => d.id == id,
    );
    return found < 0 ? 0 : found;
  }

  void _jump(int index) {
    setState(() => _index = index);
    if (_controller.hasClients) _controller.jumpToPage(index);
  }

  void _goTo(int index) {
    if (index == _index) return;
    final int previous = _index;
    setState(() => _index = index);
    if (!_controller.hasClients) return;

    // A one-step move reads as a slide; a two- or three-step move reads as a
    // blur, so it is cut instead. Reduced-motion always cuts.
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion || (index - previous).abs() > 1) {
      _controller.jumpToPage(index);
    } else {
      _controller.animateToPage(
        index,
        duration: kTabScrollDuration,
        curve: Curves.easeOut,
      );
    }
  }

  void _onDestinationSelected(int index) {
    ref.read(shellTabProvider.notifier).select(widget.destinations[index].id);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String>(shellTabProvider, (String? _, String next) {
      _goTo(_indexOf(next));
    });

    final AikoL10n l10n = AikoL10n.of(context);
    final Widget pages = PageView.builder(
      controller: _controller,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: widget.destinations.length,
      itemBuilder: (BuildContext context, int i) =>
          widget.destinations[i].builder(context),
    );

    return PopScope<Object?>(
      // Back from a secondary tab returns to the dashboard rather than
      // leaving the app — the same expectation a bottom bar sets everywhere
      // else on Android.
      canPop: _index == 0,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) return;
        ref
            .read(shellTabProvider.notifier)
            .select(widget.destinations.first.id);
      },
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool compact =
              constraints.maxWidth < AikoDims.compactWidthBreakpoint;
          return Scaffold(
            // Horizontal insets (a landscape cutout, a curved edge) are eaten
            // once here so neither the bar nor the pages have to think about
            // them. Top and bottom stay for the app bars and the nav bar.
            body: SafeArea(
              top: false,
              bottom: false,
              child: compact
                  ? _CompactShell(
                      pages: pages,
                      destinations: widget.destinations,
                      selectedIndex: _index,
                      onSelected: _onDestinationSelected,
                      l10n: l10n,
                    )
                  : _ExpandedShell(
                      pages: pages,
                      destinations: widget.destinations,
                      selectedIndex: _index,
                      onSelected: _onDestinationSelected,
                      l10n: l10n,
                    ),
            ),
          );
        },
      ),
    );
  }
}

/// Phone layout: pages over a bottom `NavigationBar`.
class _CompactShell extends StatelessWidget {
  const _CompactShell({
    required this.pages,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
    required this.l10n,
  });

  final Widget pages;
  final List<ShellDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final AikoL10n l10n;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Expanded(
          // The bar below already stands on the gesture inset; leaving it in
          // the pages' MediaQuery would inset every page a second time and
          // float the FAB well above where it belongs.
          child: MediaQuery.removePadding(
            context: context,
            removeBottom: true,
            child: pages,
          ),
        ),
        SafeArea(
          top: false,
          child: NavigationBar(
            selectedIndex: selectedIndex,
            onDestinationSelected: onSelected,
            destinations: <Widget>[
              for (final ShellDestination d in destinations)
                NavigationDestination(
                  icon: Icon(d.icon),
                  selectedIcon: Icon(d.selectedIcon),
                  label: l10n.t(d.labelKey),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Tablet / landscape layout: a rail beside the pages.
class _ExpandedShell extends StatelessWidget {
  const _ExpandedShell({
    required this.pages,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
    required this.l10n,
  });

  final Widget pages;
  final List<ShellDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final AikoL10n l10n;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Row(
      children: <Widget>[
        Material(
          color: scheme.surfaceContainer,
          child: SafeArea(
            right: false,
            left: false,
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                // A rail with four labelled destinations still overflows a
                // 320 dp-tall landscape window on a small phone, so it
                // scrolls rather than throwing a layout error.
                return SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: IntrinsicHeight(
                      child: NavigationRail(
                        selectedIndex: selectedIndex,
                        onDestinationSelected: onSelected,
                        labelType: NavigationRailLabelType.all,
                        groupAlignment: -0.85,
                        destinations: <NavigationRailDestination>[
                          for (final ShellDestination d in destinations)
                            NavigationRailDestination(
                              icon: Icon(d.icon),
                              selectedIcon: Icon(d.selectedIcon),
                              label: Text(l10n.t(d.labelKey)),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        VerticalDivider(width: 1, thickness: 1, color: scheme.outlineVariant),
        Expanded(child: pages),
      ],
    );
  }
}
