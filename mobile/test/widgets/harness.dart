import 'package:aikobox_mobile/theme/theme.dart';
import 'package:flutter/material.dart';

/// Hosts [child] inside a real AikoBox theme so widget tests exercise the same
/// `ColorScheme` the app ships with, not Flutter's defaults.
Widget hostWidget(
  Widget child, {
  Brightness brightness = Brightness.light,
  double? width,
  Alignment alignment = Alignment.center,
}) {
  final theme = brightness == Brightness.dark
      ? AikoTheme.dark()
      : AikoTheme.light();

  Widget body = child;
  if (width != null) {
    body = SizedBox(width: width, child: body);
  }

  return MaterialApp(
    theme: theme,
    home: Scaffold(body: Align(alignment: alignment, child: body)),
  );
}

/// The `ColorScheme` [hostWidget] will apply.
ColorScheme hostScheme(Brightness brightness) =>
    (brightness == Brightness.dark ? AikoTheme.dark() : AikoTheme.light())
        .colorScheme;
