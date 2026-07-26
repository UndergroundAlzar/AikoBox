import 'package:flutter/material.dart';

/// The page shell.
///
/// A large plain title at the top left, no app-bar elevation, no scroll tint,
/// transparent bar over the page surface. Every top-level page and every
/// pushed sub-page uses this so the shell never changes shape between them.
///
/// [title] is already-localised display text.
class AikoScaffold extends StatelessWidget {
  const AikoScaffold({
    super.key,
    required this.body,
    this.title,
    this.titleWidget,
    this.actions = const <Widget>[],
    this.leading,
    this.automaticallyImplyLeading = true,
    this.bottom,
    this.floatingActionButton,
    this.floatingActionButtonLocation,
    this.bottomNavigationBar,
    this.backgroundColor,
    this.resizeToAvoidBottomInset,
    this.showAppBar = true,
    this.safeAreaBottom = true,
  });

  final Widget body;

  /// Page title. Ignored when [titleWidget] is supplied.
  final String? title;

  /// Replaces the title outright — a search field, a tab strip header, …
  final Widget? titleWidget;

  final List<Widget> actions;
  final Widget? leading;
  final bool automaticallyImplyLeading;

  /// Sits under the title, inside the app bar. A `TabBar`, typically.
  final PreferredSizeWidget? bottom;

  final Widget? floatingActionButton;
  final FloatingActionButtonLocation? floatingActionButtonLocation;
  final Widget? bottomNavigationBar;

  final Color? backgroundColor;
  final bool? resizeToAvoidBottomInset;

  /// Set false for pages that draw their own header.
  final bool showAppBar;

  /// Whether the body should inset for the bottom system inset. Turn it off
  /// when the page sits above a navigation bar that already did.
  final bool safeAreaBottom;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      resizeToAvoidBottomInset: resizeToAvoidBottomInset,
      appBar: showAppBar
          ? AppBar(
              // The bar itself is transparent; the page surface shows through,
              // which is what makes content look like it scrolls under nothing.
              backgroundColor: Colors.transparent,
              surfaceTintColor: Colors.transparent,
              shadowColor: Colors.transparent,
              elevation: 0,
              scrolledUnderElevation: 0,
              automaticallyImplyLeading: automaticallyImplyLeading,
              leading: leading,
              centerTitle: false,
              title: titleWidget ?? (title != null ? Text(title!) : null),
              actions: actions.isEmpty ? null : actions,
              bottom: bottom,
            )
          : null,
      body: SafeArea(top: false, bottom: safeAreaBottom, child: body),
      floatingActionButton: floatingActionButton,
      floatingActionButtonLocation: floatingActionButtonLocation,
      bottomNavigationBar: bottomNavigationBar,
    );
  }
}
