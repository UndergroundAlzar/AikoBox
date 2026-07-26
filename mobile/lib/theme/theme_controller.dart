import 'dart:async';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// See the note in app_theme.dart: CorePalette is what dynamic_color actually
// hands back on Android, deprecation notwithstanding.
import 'package:material_color_utilities/material_color_utilities.dart'
    // ignore: deprecated_member_use
    show CorePalette;
import 'package:shared_preferences/shared_preferences.dart';

import 'app_theme.dart';
import 'seed_colors.dart';

/// The three things the user can change about the app's appearance.
@immutable
class AikoThemeSettings {
  const AikoThemeSettings({
    this.themeMode = ThemeMode.system,
    this.seedColorId = kAikoDefaultSeedColorId,
    this.useDynamicColor = true,
  });

  final ThemeMode themeMode;

  /// [AikoSeedColor.id] of the chosen palette entry.
  final String seedColorId;

  /// Prefer the device's Material You palette over [seedColorId] when the OS
  /// actually provides one (Android 12+). Ignored elsewhere.
  final bool useDynamicColor;

  static const AikoThemeSettings defaults = AikoThemeSettings();

  AikoSeedColor get seedColor => aikoSeedColorById(seedColorId);

  AikoThemeSettings copyWith({
    ThemeMode? themeMode,
    String? seedColorId,
    bool? useDynamicColor,
  }) {
    return AikoThemeSettings(
      themeMode: themeMode ?? this.themeMode,
      seedColorId: seedColorId ?? this.seedColorId,
      useDynamicColor: useDynamicColor ?? this.useDynamicColor,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AikoThemeSettings &&
          other.themeMode == themeMode &&
          other.seedColorId == seedColorId &&
          other.useDynamicColor == useDynamicColor;

  @override
  int get hashCode => Object.hash(themeMode, seedColorId, useDynamicColor);

  @override
  String toString() =>
      'AikoThemeSettings(themeMode: ${themeMode.name}, '
      'seedColorId: $seedColorId, useDynamicColor: $useDynamicColor)';
}

/// shared_preferences keys. Namespaced so they cannot collide with the
/// app-config store the core layer owns.
const String kThemeModePrefKey = 'aiko.theme.mode';
const String kThemeSeedPrefKey = 'aiko.theme.seedColor';
const String kThemeDynamicPrefKey = 'aiko.theme.useDynamicColor';

/// Override this at `ProviderScope` with a value read before `runApp` to avoid
/// the one-frame flash of default colours on cold start:
///
/// ```dart
/// final settings = await ThemeController.loadPersisted();
/// runApp(ProviderScope(
///   overrides: [preloadedThemeSettingsProvider.overrideWithValue(settings)],
///   child: const AikoApp(),
/// ));
/// ```
///
/// Leaving it alone is fine — the controller then restores asynchronously.
final Provider<AikoThemeSettings?> preloadedThemeSettingsProvider =
    Provider<AikoThemeSettings?>((ref) => null);

/// Persisted appearance settings.
class ThemeController extends Notifier<AikoThemeSettings> {
  bool _restoreStarted = false;
  bool _disposed = false;

  @override
  AikoThemeSettings build() {
    ref.onDispose(() => _disposed = true);

    final preloaded = ref.watch(preloadedThemeSettingsProvider);
    if (preloaded != null) {
      _restoreStarted = true;
      return preloaded;
    }

    if (!_restoreStarted) {
      _restoreStarted = true;
      unawaited(
        loadPersisted().then((restored) {
          if (_disposed) return;
          state = restored;
        }),
      );
    }
    return AikoThemeSettings.defaults;
  }

  /// Reads the settings straight out of shared_preferences.
  ///
  /// Never throws: a corrupt or unreadable preference store falls back to
  /// [AikoThemeSettings.defaults] rather than taking the app down over a colour.
  static Future<AikoThemeSettings> loadPersisted() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return AikoThemeSettings(
        themeMode: _decodeThemeMode(prefs.getString(kThemeModePrefKey)),
        seedColorId: aikoSeedColorById(prefs.getString(kThemeSeedPrefKey)).id,
        useDynamicColor: prefs.getBool(kThemeDynamicPrefKey) ?? true,
      );
    } catch (error, stack) {
      debugPrint('ThemeController: failed to read theme settings: $error');
      debugPrintStack(stackTrace: stack);
      return AikoThemeSettings.defaults;
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (state.themeMode == mode) return;
    state = state.copyWith(themeMode: mode);
    await _persist();
  }

  /// [seedColorId] must be an [AikoSeedColor.id]; unknown ids resolve to the
  /// default rather than being stored verbatim.
  Future<void> setSeedColor(String seedColorId) async {
    final resolved = aikoSeedColorById(seedColorId).id;
    if (state.seedColorId == resolved) return;
    state = state.copyWith(seedColorId: resolved);
    await _persist();
  }

  Future<void> setUseDynamicColor(bool value) async {
    if (state.useDynamicColor == value) return;
    state = state.copyWith(useDynamicColor: value);
    await _persist();
  }

  Future<void> resetToDefaults() async {
    if (state == AikoThemeSettings.defaults) return;
    state = AikoThemeSettings.defaults;
    await _persist();
  }

  Future<void> _persist() async {
    final snapshot = state;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kThemeModePrefKey, snapshot.themeMode.name);
      await prefs.setString(kThemeSeedPrefKey, snapshot.seedColorId);
      await prefs.setBool(kThemeDynamicPrefKey, snapshot.useDynamicColor);
    } catch (error) {
      // The in-memory state stays applied; only persistence failed. Surfacing a
      // dialog for this would be worse than a log line.
      debugPrint('ThemeController: failed to persist theme settings: $error');
    }
  }

  static ThemeMode _decodeThemeMode(String? raw) {
    return switch (raw) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }
}

final NotifierProvider<ThemeController, AikoThemeSettings>
themeControllerProvider =
    NotifierProvider<ThemeController, AikoThemeSettings>(ThemeController.new);

/// Convenience selector for `MaterialApp.themeMode`.
final Provider<ThemeMode> themeModeProvider = Provider<ThemeMode>(
  (ref) => ref.watch(themeControllerProvider.select((s) => s.themeMode)),
);

/// The device's Material You palette, or null when the OS does not offer one
/// (pre-Android 12, or any non-Android platform).
// ignore: deprecated_member_use
final FutureProvider<CorePalette?> dynamicCorePaletteProvider =
    // ignore: deprecated_member_use
    FutureProvider<CorePalette?>((ref) async {
      try {
        return await DynamicColorPlugin.getCorePalette();
      } catch (error) {
        debugPrint('ThemeController: dynamic colour unavailable: $error');
        return null;
      }
    });

/// `MaterialApp.theme`.
final Provider<ThemeData> lightThemeProvider = Provider<ThemeData>((ref) {
  final settings = ref.watch(themeControllerProvider);
  final palette = ref.watch(dynamicCorePaletteProvider).value;
  return AikoTheme.light(
    seedColor: settings.seedColor.color,
    corePalette: palette,
    useDynamicColor: settings.useDynamicColor,
  );
});

/// `MaterialApp.darkTheme`.
final Provider<ThemeData> darkThemeProvider = Provider<ThemeData>((ref) {
  final settings = ref.watch(themeControllerProvider);
  final palette = ref.watch(dynamicCorePaletteProvider).value;
  return AikoTheme.dark(
    seedColor: settings.seedColor.color,
    corePalette: palette,
    useDynamicColor: settings.useDynamicColor,
  );
});
