/// Keeps the two places appearance lives from drifting apart.
///
/// `ThemeController` (shared_preferences) is what `MaterialApp` actually reads,
/// so it is authoritative at runtime. `AppConfig` (config.json) carries the same
/// three values because that file is what backup/restore round-trips and what
/// the desktop app persists — a backup that lost the user's theme would be a
/// poor backup.
///
/// Every write goes through [applyAppearance] so the two never diverge.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../theme/theme.dart';

/// `AppConfig`'s spelling of a Flutter [ThemeMode].
AppThemeMode appThemeModeOf(ThemeMode mode) => switch (mode) {
  ThemeMode.light => AppThemeMode.light,
  ThemeMode.dark => AppThemeMode.dark,
  ThemeMode.system => AppThemeMode.system,
};

/// Flutter's spelling of an [AppThemeMode].
ThemeMode themeModeOf(AppThemeMode mode) => switch (mode) {
  AppThemeMode.light => ThemeMode.light,
  AppThemeMode.dark => ThemeMode.dark,
  AppThemeMode.system => ThemeMode.system,
};

/// The ARGB value `AppConfig.seedColor` should carry for a palette entry id.
int seedArgbForId(String seedColorId) =>
    aikoSeedColorById(seedColorId).color.toARGB32();

/// The palette entry id for a persisted ARGB value.
///
/// A value that matches no shipped swatch resolves to the default rather than
/// being invented, which is the same rule [aikoSeedColorById] applies to ids.
String seedIdForArgb(int argb) {
  for (final AikoSeedColor seed in kAikoSeedColors) {
    if (seed.color.toARGB32() == argb) return seed.id;
  }
  return kAikoDefaultSeedColorId;
}

/// Writes an appearance change to both stores.
///
/// Only the fields that are non-null change. The `ThemeController` write is
/// awaited first because it is the one the UI is about to re-render from; the
/// `AppConfig` mirror follows so a failed disk write cannot leave the app
/// looking like the change was rejected.
Future<void> applyAppearance(
  WidgetRef ref, {
  ThemeMode? themeMode,
  String? seedColorId,
  bool? useDynamicColor,
}) async {
  final ThemeController controller = ref.read(themeControllerProvider.notifier);
  if (themeMode != null) await controller.setThemeMode(themeMode);
  if (seedColorId != null) await controller.setSeedColor(seedColorId);
  if (useDynamicColor != null) {
    await controller.setUseDynamicColor(useDynamicColor);
  }

  try {
    await ref
        .read(appConfigProvider.notifier)
        .update(
          (AppConfig current) => current.copyWith(
            appTheme: themeMode == null ? null : appThemeModeOf(themeMode),
            seedColor: seedColorId == null ? null : seedArgbForId(seedColorId),
            useDynamicColor: useDynamicColor,
          ),
        );
  } catch (_) {
    // The mirror is a convenience for backup/restore. shared_preferences
    // already has the authoritative value, so a config.json write failure must
    // not undo a theme the user can see has changed.
  }
}

/// Pushes appearance values that came from a restored backup into the live
/// `ThemeController`.
Future<void> adoptAppearanceFromConfig(WidgetRef ref, AppConfig config) async {
  final ThemeController controller = ref.read(themeControllerProvider.notifier);
  await controller.setThemeMode(themeModeOf(config.appTheme));
  await controller.setSeedColor(seedIdForArgb(config.seedColor));
  await controller.setUseDynamicColor(config.useDynamicColor);
}
