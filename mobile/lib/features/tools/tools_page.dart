/// Compatibility shim.
///
/// `features/shell/shell_pages.dart` imports the Tools destination from
/// `features/tools/tools_page.dart`, while the page itself lives with the rest
/// of the settings section in `features/settings/`. Re-exporting rather than
/// moving keeps both file-ownership boundaries intact and costs nothing at
/// runtime.
///
/// New code should import `package:aikobox_mobile/features/settings/settings.dart`.
library;

export '../settings/tools_page.dart' show ToolsPage, kToolsRoute;
