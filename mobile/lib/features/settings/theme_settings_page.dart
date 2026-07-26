/// Appearance settings: the live preview card, the three theme-mode chips and
/// the seed-colour swatch grid described in the build contract §6.
///
/// Every control writes through [applyAppearance], so `ThemeController` (what
/// `MaterialApp` reads) and `AppConfig` (what backup/restore carries) always
/// agree.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/aiko_l10n.dart';
import '../../theme/theme.dart';
import '../../widgets/widgets.dart';
import 'appearance_sync.dart';
import 'settings_controls.dart';

/// Route name used by the shell. Kept here so the navigator and the Tools page
/// cannot disagree about it.
const String kThemeSettingsRoute = '/settings/theme';

class ThemeSettingsPage extends ConsumerWidget {
  const ThemeSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AikoL10n l10n = context.l10n;
    final AikoThemeSettings settings = ref.watch(themeControllerProvider);
    // Left inferred on purpose: naming CorePalette here would pull a deprecated
    // symbol into this file for no benefit.
    final bool paletteAvailable =
        ref.watch(dynamicCorePaletteProvider).value != null;
    final bool dynamicActive = settings.useDynamicColor && paletteAvailable;

    return AikoScaffold(
      title: l10n.t('theme.title'),
      body: SettingsBody(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AikoDims.pagePadding,
              8,
              AikoDims.pagePadding,
              4,
            ),
            child: ThemePreviewCard(label: l10n.t('theme.preview')),
          ),

          SettingsGroup(
            title: l10n.t('theme.mode.title'),
            children: <Widget>[
              AikoChoiceChips<ThemeMode>(
                options: <AikoChoiceOption<ThemeMode>>[
                  AikoChoiceOption<ThemeMode>(
                    value: ThemeMode.system,
                    label: l10n.t('settings.backgroundAuto'),
                    icon: Icons.brightness_auto_rounded,
                  ),
                  AikoChoiceOption<ThemeMode>(
                    value: ThemeMode.light,
                    label: l10n.t('settings.backgroundLight'),
                    icon: Icons.light_mode_rounded,
                  ),
                  AikoChoiceOption<ThemeMode>(
                    value: ThemeMode.dark,
                    label: l10n.t('settings.backgroundDark'),
                    icon: Icons.dark_mode_rounded,
                  ),
                ],
                value: settings.themeMode,
                onChanged: (ThemeMode mode) =>
                    applyAppearance(ref, themeMode: mode),
              ),
            ],
          ),

          SettingsGroup(
            title: l10n.t('theme.seed.title'),
            children: <Widget>[
              SettingsSwitchTile(
                tileKey: const Key('theme-dynamic-switch'),
                title: l10n.t('theme.seed.dynamic'),
                subtitle: paletteAvailable
                    ? null
                    : l10n.t('theme.seed.dynamicUnavailable'),
                icon: Icons.auto_awesome_rounded,
                value: settings.useDynamicColor,
                onChanged: (bool value) =>
                    applyAppearance(ref, useDynamicColor: value),
              ),
              SeedColorPicker(
                selectedId: settings.seedColorId,
                enabled: !dynamicActive,
                onSelected: (String id) =>
                    applyAppearance(ref, seedColorId: id),
              ),
            ],
          ),

          SettingsGroup(
            children: <Widget>[
              SettingsValueTile(
                tileKey: const Key('theme-reset'),
                title: l10n.t('common.reset'),
                icon: Icons.restart_alt_rounded,
                showChevron: false,
                onTap: () async {
                  await applyAppearance(
                    ref,
                    themeMode: AikoThemeSettings.defaults.themeMode,
                    seedColorId: AikoThemeSettings.defaults.seedColorId,
                    useDynamicColor: AikoThemeSettings.defaults.useDynamicColor,
                  );
                  if (context.mounted) {
                    showAikoSnack(context, context.l10n.t('common.saved'));
                  }
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Preview
// ---------------------------------------------------------------------------

/// A miniature of the app rendered in the theme that is currently applied.
///
/// Deliberately built from real design-system widgets ([CommonCard],
/// [Sparkline], [DelayChip]) rather than coloured rectangles, so what the user
/// sees here is literally what the rest of the app will look like. Nothing in
/// it is interactive — it is a picture, not a control panel.
class ThemePreviewCard extends StatelessWidget {
  const ThemePreviewCard({super.key, required this.label});

  /// Already-localised card header.
  final String label;

  static const List<double> _upSeries = <double>[
    2,
    6,
    3,
    9,
    14,
    8,
    12,
    20,
    16,
    11,
    18,
    24,
  ];
  static const List<double> _downSeries = <double>[
    8,
    12,
    20,
    15,
    26,
    34,
    28,
    40,
    33,
    45,
    38,
    52,
  ];

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AikoStatusColors status = AikoStatusColors.of(context);

    return CommonCard(
      icon: Icons.palette_outlined,
      label: label,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: ShapeDecoration(
                  color: scheme.primaryContainer,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Icon(
                  Icons.rocket_launch_rounded,
                  size: 20,
                  color: scheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      context.l10n.t('app.name'),
                      style: theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      context.l10n.t('app.tagline'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 44,
            child: Sparkline(
              animate: false,
              series: <SparklineSeries>[
                SparklineSeries(values: _downSeries, color: status.download),
                SparklineSeries(
                  values: _upSeries,
                  color: status.upload,
                  fill: false,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: const <Widget>[
              DelayChip(delay: 96, dense: true),
              DelayChip(delay: 812, dense: true),
              DelayChip(delay: 0, dense: true),
              _PreviewSwatchRow(),
            ],
          ),
        ],
      ),
    );
  }
}

class _PreviewSwatchRow extends StatelessWidget {
  const _PreviewSwatchRow();

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<Color> colors = <Color>[
      scheme.primary,
      scheme.secondary,
      scheme.tertiary,
      scheme.surfaceContainerHighest,
    ];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final Color color in colors)
          Container(
            width: 18,
            height: 18,
            margin: const EdgeInsetsDirectional.only(end: 6),
            decoration: ShapeDecoration(
              color: color,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(5),
                side: BorderSide(color: scheme.outlineVariant),
              ),
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Seed swatches
// ---------------------------------------------------------------------------

/// The seed palette as circular four-quadrant swatches in rounded squares.
///
/// The selected swatch gets a `primaryContainer` fill, a `primary` hairline and
/// a check mark — that is [CommonCard]'s selected state, not a bespoke one.
class SeedColorPicker extends StatelessWidget {
  const SeedColorPicker({
    super.key,
    required this.selectedId,
    required this.onSelected,
    this.enabled = true,
  });

  final String selectedId;
  final ValueChanged<String> onSelected;

  /// False while the device palette is driving the colours, in which case the
  /// swatches are shown dimmed and inert rather than hidden — the user needs to
  /// see what turning the system palette off would give them.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AikoDims.pagePadding,
        8,
        AikoDims.pagePadding,
        8,
      ),
      child: Opacity(
        opacity: enabled ? 1 : 0.45,
        child: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: <Widget>[
            for (final AikoSeedColor seed in kAikoSeedColors)
              _SeedSwatch(
                seed: seed,
                selected: seed.id == selectedId,
                onTap: enabled ? () => onSelected(seed.id) : null,
              ),
          ],
        ),
      ),
    );
  }
}

class _SeedSwatch extends StatelessWidget {
  const _SeedSwatch({
    required this.seed,
    required this.selected,
    required this.onTap,
  });

  final AikoSeedColor seed;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String? name = trOrNull(context, seed.nameKey);

    Widget disc = CustomPaint(
      painter: _QuadrantPainter(
        _quadrantColorsFor(seed, Theme.of(context).brightness),
      ),
    );
    if (name != null) {
      disc = Tooltip(message: name, child: disc);
    }

    return SizedBox(
      width: 64,
      height: 64,
      child: CommonCard(
        key: ValueKey<String>('seed-swatch-${seed.id}'),
        semanticLabel: name,
        radius: 14,
        padding: const EdgeInsets.all(10),
        isSelected: selected,
        onTap: onTap,
        selectedOverlay: Align(
          alignment: AlignmentDirectional.bottomEnd,
          child: Padding(
            padding: const EdgeInsets.all(3),
            child: Icon(
              Icons.check_circle_rounded,
              size: 16,
              color: scheme.onPrimaryContainer,
            ),
          ),
        ),
        child: disc,
      ),
    );
  }
}

/// `ColorScheme.fromSeed` is expensive enough that recomputing eight of them on
/// every rebuild is visible on a mid-range phone, and the answer only depends
/// on the seed and the brightness.
final Map<String, List<Color>> _quadrantCache = <String, List<Color>>{};

List<Color> _quadrantColorsFor(AikoSeedColor seed, Brightness brightness) {
  final String key = '${seed.id}:${brightness.name}';
  return _quadrantCache.putIfAbsent(key, () {
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: seed.color,
      brightness: brightness,
    );
    return <Color>[
      scheme.primary,
      scheme.secondary,
      scheme.tertiary,
      scheme.primaryContainer,
    ];
  });
}

/// Paints a circle split into four equal quadrants, clockwise from 12 o'clock.
class _QuadrantPainter extends CustomPainter {
  const _QuadrantPainter(this.colors);

  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    final double diameter = math.min(size.width, size.height);
    final Rect rect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: diameter,
      height: diameter,
    );
    const double quarter = math.pi / 2;
    final Paint paint = Paint()..style = PaintingStyle.fill;
    for (int i = 0; i < 4; i++) {
      paint.color = colors[i % colors.length];
      canvas.drawArc(rect, -math.pi / 2 + i * quarter, quarter, true, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _QuadrantPainter oldDelegate) =>
      !identical(oldDelegate.colors, colors);
}
