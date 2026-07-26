/// App shell and navigation.
///
/// `import 'package:aikobox_mobile/features/shell/shell.dart';` gets the
/// navigation state (`shellTabProvider`, the `kShell*Tab` ids), the permission
/// flow (`ensureTunnelPermissions`, `VpnPermissionFlow`) and the deep-link
/// machinery.
///
/// `shell_pages.dart` is deliberately **not** exported: it is the one file
/// that reaches into the feature packages, and only `app.dart` needs it.
/// Importing it from a feature would create a cycle.
library;

export 'deep_link_handler.dart';
export 'deep_link_parser.dart';
export 'home_shell.dart';
export 'notification_permission_gate.dart';
export 'shell_destination.dart';
export 'shell_host_channel.dart';
export 'shell_providers.dart';
export 'shell_snackbar.dart';
export 'vpn_permission_flow.dart';
