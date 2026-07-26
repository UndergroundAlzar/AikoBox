import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// CorePalette is soft-deprecated upstream in favour of DynamicScheme, but it is
// still exactly what `dynamic_color`'s plugin returns on Android, and the build
// contract pins the Material You path to it.
import 'package:material_color_utilities/material_color_utilities.dart'
    // ignore: deprecated_member_use
    show CorePalette;

import 'seed_colors.dart';

/// Fixed dimensions and durations of the AikoBox design system.
///
/// Every widget in `lib/widgets/` reads its geometry from here so the whole app
/// can be re-proportioned from one place.
abstract final class AikoDims {
  /// Corner radius of [CommonCard] and everything that has to sit flush with it.
  static const double cardRadius = 16;

  /// Hairline width of the card border. Kept at a logical pixel — on a 3x screen
  /// this is 3 device pixels, which is what makes the outline read as a hairline
  /// rather than a frame.
  static const double cardBorderWidth = 1;

  /// Inner padding of card content.
  static const double cardPadding = 16;

  /// Card header icon size, per the FlClash header row.
  static const double cardHeaderIconSize = 18;

  /// Gap between header icon and header label.
  static const double cardHeaderGap = 8;

  /// Gutter between dashboard grid cells.
  static const double gridSpacing = 12;

  /// Horizontal page margin.
  static const double pagePadding = 16;

  /// Bottom padding a scrollable page needs to clear the FAB.
  static const double fabClearance = 88;

  /// Diameter of the collapsed FAB.
  static const double fabSize = 56;

  /// FAB corner radius (M3 "large" FAB shape).
  static const double fabRadius = 16;

  /// Top corner radius of modal bottom sheets.
  static const double sheetRadius = 28;

  /// Proxy grid: a cell wants roughly this much width before another column is
  /// added. Matches FlClash's `max((width / 250).ceil(), 2)`.
  static const double proxyCellWidth = 250;

  /// Dashboard: a 1-column card wants roughly this much width.
  static const double dashboardCellWidth = 280;

  /// Width at which the shell switches from NavigationBar to NavigationRail.
  static const double compactWidthBreakpoint = 600;

  static const Duration fastMotion = Duration(milliseconds: 120);
  static const Duration midMotion = Duration(milliseconds: 220);
  static const Duration slowMotion = Duration(milliseconds: 320);
}

/// Semantic colours that Material 3 does not define but this app needs:
/// latency verdicts and the up/down traffic pair.
///
/// Registered on both themes as a [ThemeExtension] so the values are tuned per
/// brightness instead of one set of constants being forced through both.
@immutable
class AikoStatusColors extends ThemeExtension<AikoStatusColors> {
  const AikoStatusColors({
    required this.good,
    required this.onGoodContainer,
    required this.goodContainer,
    required this.warn,
    required this.onWarnContainer,
    required this.warnContainer,
    required this.bad,
    required this.onBadContainer,
    required this.badContainer,
    required this.upload,
    required this.download,
    required this.neutralContainer,
    required this.onNeutralContainer,
  });

  /// Latency under [kAikoGoodDelayCeiling] ms.
  final Color good;
  final Color goodContainer;
  final Color onGoodContainer;

  /// Latency at or over [kAikoGoodDelayCeiling] ms.
  final Color warn;
  final Color warnContainer;
  final Color onWarnContainer;

  /// The probe failed or timed out.
  final Color bad;
  final Color badContainer;
  final Color onBadContainer;

  /// Traffic direction accents, used by the sparkline and the traffic card.
  final Color upload;
  final Color download;

  /// "Not measured yet" pill.
  final Color neutralContainer;
  final Color onNeutralContainer;

  static const AikoStatusColors _light = AikoStatusColors(
    good: Color(0xFF1B7F3B),
    goodContainer: Color(0xFFD8F0DF),
    onGoodContainer: Color(0xFF0C4A21),
    warn: Color(0xFFB07000),
    warnContainer: Color(0xFFFBEBCC),
    onWarnContainer: Color(0xFF6A4300),
    bad: Color(0xFFC62828),
    badContainer: Color(0xFFFBDDDD),
    onBadContainer: Color(0xFF7A1414),
    upload: Color(0xFF7B4FD1),
    download: Color(0xFF1E7FBF),
    neutralContainer: Color(0x14000000),
    onNeutralContainer: Color(0xFF5B5B5B),
  );

  static const AikoStatusColors _dark = AikoStatusColors(
    good: Color(0xFF6FD08C),
    goodContainer: Color(0xFF14361F),
    onGoodContainer: Color(0xFFA9E8BC),
    warn: Color(0xFFE7B44B),
    warnContainer: Color(0xFF3A2C0B),
    onWarnContainer: Color(0xFFF3D294),
    bad: Color(0xFFF08A8A),
    badContainer: Color(0xFF421515),
    onBadContainer: Color(0xFFF7B9B9),
    upload: Color(0xFFB69BF3),
    download: Color(0xFF74BEEA),
    neutralContainer: Color(0x1FFFFFFF),
    onNeutralContainer: Color(0xFFB6B6B6),
  );

  /// The tuned set for [brightness].
  static AikoStatusColors forBrightness(Brightness brightness) =>
      brightness == Brightness.dark ? _dark : _light;

  /// Reads the extension off [context], falling back to the brightness default
  /// so widgets still render sanely inside a bare `MaterialApp` (tests, previews).
  static AikoStatusColors of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<AikoStatusColors>() ??
        forBrightness(theme.brightness);
  }

  @override
  AikoStatusColors copyWith({
    Color? good,
    Color? goodContainer,
    Color? onGoodContainer,
    Color? warn,
    Color? warnContainer,
    Color? onWarnContainer,
    Color? bad,
    Color? badContainer,
    Color? onBadContainer,
    Color? upload,
    Color? download,
    Color? neutralContainer,
    Color? onNeutralContainer,
  }) {
    return AikoStatusColors(
      good: good ?? this.good,
      goodContainer: goodContainer ?? this.goodContainer,
      onGoodContainer: onGoodContainer ?? this.onGoodContainer,
      warn: warn ?? this.warn,
      warnContainer: warnContainer ?? this.warnContainer,
      onWarnContainer: onWarnContainer ?? this.onWarnContainer,
      bad: bad ?? this.bad,
      badContainer: badContainer ?? this.badContainer,
      onBadContainer: onBadContainer ?? this.onBadContainer,
      upload: upload ?? this.upload,
      download: download ?? this.download,
      neutralContainer: neutralContainer ?? this.neutralContainer,
      onNeutralContainer: onNeutralContainer ?? this.onNeutralContainer,
    );
  }

  @override
  AikoStatusColors lerp(ThemeExtension<AikoStatusColors>? other, double t) {
    if (other is! AikoStatusColors) return this;
    return AikoStatusColors(
      good: Color.lerp(good, other.good, t)!,
      goodContainer: Color.lerp(goodContainer, other.goodContainer, t)!,
      onGoodContainer: Color.lerp(onGoodContainer, other.onGoodContainer, t)!,
      warn: Color.lerp(warn, other.warn, t)!,
      warnContainer: Color.lerp(warnContainer, other.warnContainer, t)!,
      onWarnContainer: Color.lerp(onWarnContainer, other.onWarnContainer, t)!,
      bad: Color.lerp(bad, other.bad, t)!,
      badContainer: Color.lerp(badContainer, other.badContainer, t)!,
      onBadContainer: Color.lerp(onBadContainer, other.onBadContainer, t)!,
      upload: Color.lerp(upload, other.upload, t)!,
      download: Color.lerp(download, other.download, t)!,
      neutralContainer: Color.lerp(
        neutralContainer,
        other.neutralContainer,
        t,
      )!,
      onNeutralContainer: Color.lerp(
        onNeutralContainer,
        other.onNeutralContainer,
        t,
      )!,
    );
  }
}

/// Latency at or above this many milliseconds is shown amber instead of green.
/// Ported from FlClash's `getDelayColor`.
const int kAikoGoodDelayCeiling = 600;

/// Builds the two `ThemeData`s the app runs on.
abstract final class AikoTheme {
  /// Light theme.
  static ThemeData light({
    Color seedColor = kAikoDefaultSeedColorValue,
    // ignore: deprecated_member_use
    CorePalette? corePalette,
    bool useDynamicColor = false,
  }) {
    return _build(
      Brightness.light,
      resolveSeed(
        seedColor: seedColor,
        corePalette: corePalette,
        useDynamicColor: useDynamicColor,
      ),
    );
  }

  /// Dark theme.
  static ThemeData dark({
    Color seedColor = kAikoDefaultSeedColorValue,
    // ignore: deprecated_member_use
    CorePalette? corePalette,
    bool useDynamicColor = false,
  }) {
    return _build(
      Brightness.dark,
      resolveSeed(
        seedColor: seedColor,
        corePalette: corePalette,
        useDynamicColor: useDynamicColor,
      ),
    );
  }

  /// Picks the seed the schemes are derived from.
  ///
  /// When the device supplies a Material You `CorePalette` and the user has not
  /// opted out, tone 40 of its primary tonal palette is used as the seed. Taking
  /// the *seed* rather than `CorePalette.toColorScheme()` is deliberate: that
  /// helper predates the `surfaceContainer*` roles and returns a scheme missing
  /// the whole surface ladder this design system draws cards on.
  static Color resolveSeed({
    required Color seedColor,
    // ignore: deprecated_member_use
    CorePalette? corePalette,
    bool useDynamicColor = false,
  }) {
    if (useDynamicColor && corePalette != null) {
      return Color(corePalette.primary.get(40));
    }
    return seedColor;
  }

  /// The status-bar / navigation-bar icon brightness that matches [brightness].
  static SystemUiOverlayStyle systemOverlayStyleFor(Brightness brightness) {
    return brightness == Brightness.dark
        ? SystemUiOverlayStyle.light
        : SystemUiOverlayStyle.dark;
  }

  static ThemeData _build(Brightness brightness, Color seed) {
    final isDark = brightness == Brightness.dark;
    final raw = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );
    final scheme = isDark ? _tuneDark(raw) : _tuneLight(raw);
    final textTheme = _textTheme(scheme, brightness);
    final statusColors = AikoStatusColors.forBrightness(brightness);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      textTheme: textTheme,
      scaffoldBackgroundColor: scheme.surface,
      canvasColor: scheme.surface,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,
      extensions: <ThemeExtension<dynamic>>[statusColors],

      // Pages carry a large plain title on a transparent bar. No elevation, no
      // tint on scroll — the content scrolls under a flat surface.
      appBarTheme: AppBarThemeData(
        backgroundColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        toolbarHeight: 64,
        titleSpacing: AikoDims.pagePadding,
        systemOverlayStyle: systemOverlayStyleFor(brightness),
        titleTextStyle: textTheme.headlineSmall?.copyWith(
          color: scheme.onSurface,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
        iconTheme: IconThemeData(color: scheme.onSurfaceVariant, size: 22),
        actionsIconTheme: IconThemeData(
          color: scheme.onSurfaceVariant,
          size: 22,
        ),
      ),

      navigationBarTheme: NavigationBarThemeData(
        height: 80,
        elevation: 0,
        backgroundColor: scheme.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        indicatorColor: scheme.secondaryContainer,
        indicatorShape: const StadiumBorder(),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return IconThemeData(
              size: 24,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.38),
            );
          }
          return IconThemeData(
            size: 24,
            color: states.contains(WidgetState.selected)
                ? scheme.onSecondaryContainer
                : scheme.onSurfaceVariant,
          );
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final base = textTheme.labelMedium ?? const TextStyle();
          if (states.contains(WidgetState.disabled)) {
            return base.copyWith(
              color: scheme.onSurfaceVariant.withValues(alpha: 0.38),
            );
          }
          return base.copyWith(
            overflow: TextOverflow.ellipsis,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w500,
            color: states.contains(WidgetState.selected)
                ? scheme.onSurface
                : scheme.onSurfaceVariant,
          );
        }),
      ),

      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: Colors.transparent,
        elevation: 0,
        indicatorColor: scheme.secondaryContainer,
        indicatorShape: const StadiumBorder(),
        useIndicator: true,
        selectedIconTheme: IconThemeData(
          size: 24,
          color: scheme.onSecondaryContainer,
        ),
        unselectedIconTheme: IconThemeData(
          size: 24,
          color: scheme.onSurfaceVariant,
        ),
        selectedLabelTextStyle: textTheme.labelLarge?.copyWith(
          color: scheme.onSurface,
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelTextStyle: textTheme.labelLarge?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),

      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AikoDims.pagePadding,
        ),
        minVerticalPadding: 12,
        titleAlignment: ListTileTitleAlignment.center,
        iconColor: scheme.onSurfaceVariant,
        textColor: scheme.onSurface,
        titleTextStyle: textTheme.bodyLarge?.copyWith(color: scheme.onSurface),
        subtitleTextStyle: textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        leadingAndTrailingTextStyle: textTheme.labelMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),

      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),

      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primaryContainer,
        foregroundColor: scheme.onPrimaryContainer,
        // A dark surface already separates the FAB from the page; a drop shadow
        // there just muddies it. Light needs the lift.
        elevation: isDark ? 0 : 3,
        focusElevation: isDark ? 0 : 3,
        hoverElevation: isDark ? 0 : 4,
        highlightElevation: isDark ? 0 : 1,
        splashColor: scheme.onPrimaryContainer.withValues(alpha: 0.12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AikoDims.fabRadius),
        ),
        extendedTextStyle: textTheme.titleSmall?.copyWith(
          color: scheme.onPrimaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ),

      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        modalBackgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        modalBarrierColor: scheme.scrim.withValues(alpha: isDark ? 0.62 : 0.42),
        elevation: 0,
        modalElevation: 0,
        showDragHandle: true,
        dragHandleColor: scheme.onSurfaceVariant.withValues(alpha: 0.4),
        clipBehavior: Clip.antiAlias,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AikoDims.sheetRadius),
          ),
        ),
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AikoDims.sheetRadius),
        ),
        titleTextStyle: textTheme.titleLarge?.copyWith(
          color: scheme.onSurface,
        ),
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),

      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
        actionTextColor: scheme.inversePrimary,
        elevation: isDark ? 0 : 2,
        insetPadding: const EdgeInsets.all(AikoDims.pagePadding),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),

      chipTheme: ChipThemeData(
        backgroundColor: Colors.transparent,
        selectedColor: scheme.secondaryContainer,
        side: BorderSide(color: scheme.outlineVariant),
        labelStyle: textTheme.labelMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        secondaryLabelStyle: textTheme.labelMedium?.copyWith(
          color: scheme.onSecondaryContainer,
        ),
        labelPadding: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        showCheckmark: false,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),

      inputDecorationTheme: InputDecorationThemeData(
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(
          alpha: isDark ? 0.55 : 0.7,
        ),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        hintStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.error, width: 2),
        ),
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          textStyle: textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          foregroundColor: scheme.onSurface,
          side: BorderSide(color: scheme.outlineVariant),
          textStyle: textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 40),
          textStyle: textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),

      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: scheme.onSurfaceVariant,
          highlightColor: scheme.primary.withValues(alpha: 0.10),
        ),
      ),

      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          selectedBackgroundColor: scheme.secondaryContainer,
          selectedForegroundColor: scheme.onSecondaryContainer,
          foregroundColor: scheme.onSurfaceVariant,
          side: BorderSide(color: scheme.outlineVariant),
          textStyle: textTheme.labelLarge,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),

      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.surfaceContainerHighest,
        circularTrackColor: Colors.transparent,
      ),

      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 400),
        decoration: ShapeDecoration(
          color: scheme.inverseSurface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        textStyle: textTheme.bodySmall?.copyWith(
          color: scheme.onInverseSurface,
        ),
      ),

      scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll(6),
        radius: const Radius.circular(6),
        thumbColor: WidgetStatePropertyAll(
          scheme.onSurfaceVariant.withValues(alpha: isDark ? 0.35 : 0.28),
        ),
      ),

      tabBarTheme: TabBarThemeData(
        dividerColor: Colors.transparent,
        indicatorColor: scheme.primary,
        indicatorSize: TabBarIndicatorSize.label,
        labelColor: scheme.onSurface,
        unselectedLabelColor: scheme.onSurfaceVariant,
        labelStyle: textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelStyle: textTheme.titleSmall,
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      ),

      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        elevation: isDark ? 0 : 3,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        textStyle: textTheme.bodyMedium?.copyWith(color: scheme.onSurface),
      ),

      switchTheme: SwitchThemeData(
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Colors.transparent
              : scheme.outline,
        ),
      ),

      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
        },
      ),
    );
  }

  /// Light-mode corrections on top of `ColorScheme.fromSeed`.
  static ColorScheme _tuneLight(ColorScheme s) {
    return s.copyWith(
      // Every surface in this app is drawn as a 1 px outlineVariant hairline over
      // a transparent fill. M3's light outlineVariant (tone 80) against a tone-98
      // surface is too faint for that to read as a boundary, so pull it a step
      // toward onSurfaceVariant.
      outlineVariant: Color.lerp(s.outlineVariant, s.onSurfaceVariant, 0.16)!,
      // Keep the page a clean near-white and let the surfaceContainer ladder do
      // the layering; fromSeed's tone-98 surface is close enough that a card with
      // a surfaceContainerLow fill barely separates from it.
      surface: Color.lerp(s.surface, Colors.white, 0.45)!,
      surfaceContainerLowest: Colors.white,
    );
  }

  /// Dark-mode corrections on top of `ColorScheme.fromSeed`.
  ///
  /// These are not the light values inverted. Dark mode has two specific
  /// problems the light scheme does not: hairlines disappear, and M3's dark
  /// surface ladder is compressed into a narrow band that looks washed out on
  /// an OLED panel. Both are fixed here, keeping the ladder monotonic.
  static ColorScheme _tuneDark(ColorScheme s) {
    return s.copyWith(
      outlineVariant: Color.lerp(s.outlineVariant, s.onSurfaceVariant, 0.30)!,
      surface: _deepen(s.surface, 0.20),
      surfaceContainerLowest: _deepen(s.surfaceContainerLowest, 0.30),
      surfaceContainerLow: _deepen(s.surfaceContainerLow, 0.12),
      surfaceContainer: _deepen(s.surfaceContainer, 0.10),
      surfaceContainerHigh: _deepen(s.surfaceContainerHigh, 0.06),
      surfaceContainerHighest: _deepen(s.surfaceContainerHighest, 0.04),
    );
  }

  static Color _deepen(Color c, double t) => Color.lerp(c, Colors.black, t)!;

  static TextTheme _textTheme(ColorScheme scheme, Brightness brightness) {
    final typography = Typography.material2021(
      platform: TargetPlatform.android,
      colorScheme: scheme,
    );
    final base = brightness == Brightness.dark
        ? typography.white
        : typography.black;

    return base
        .copyWith(
          // Card header labels. Slightly heavier than stock so the header reads
          // as a header at 14 px without needing a divider under it.
          titleSmall: base.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.1,
          ),
          // Delay pills and other numeric badges: tabular figures stop the pill
          // from jittering as the value changes.
          labelSmall: base.labelSmall?.copyWith(
            fontWeight: FontWeight.w600,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        )
        .apply(
          bodyColor: scheme.onSurface,
          displayColor: scheme.onSurface,
          decorationColor: scheme.onSurface,
        );
  }
}
