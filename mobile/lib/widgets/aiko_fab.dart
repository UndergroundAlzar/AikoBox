import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The start/stop FAB.
///
/// Stopped it is a 56 px rocket button. Running it widens into a pill showing a
/// pause glyph and the elapsed `HH:MM:SS`. That is one [AnimatedContainer]
/// morphing — not a cross-fade between two buttons — so the corner radius, the
/// fill and the width all travel together and the icon never jumps.
///
/// The elapsed clock is driven from [startedAt] by an internal one-second
/// ticker, which only runs while the FAB is actually running.
class AikoFab extends StatefulWidget {
  const AikoFab({
    super.key,
    required this.running,
    this.onPressed,
    this.startedAt,
    this.busy = false,
    this.tooltip,
    this.semanticLabel,
    this.stoppedIcon = Icons.rocket_launch_rounded,
    this.runningIcon = Icons.pause_rounded,
  });

  /// Whether the tunnel is up.
  final bool running;

  /// Null disables the button.
  final VoidCallback? onPressed;

  /// When the current session started. Null shows `00:00:00` and starts no
  /// ticker — useful while the state is still settling.
  final DateTime? startedAt;

  /// Transition in flight: shows a spinner in place of the glyph.
  final bool busy;

  /// Already-localised tooltip.
  final String? tooltip;

  /// Already-localised accessibility label.
  final String? semanticLabel;

  final IconData stoppedIcon;
  final IconData runningIcon;

  /// `HH:MM:SS`, with hours running past 24 rather than wrapping.
  static String formatElapsed(Duration duration) {
    final d = duration.isNegative ? Duration.zero : duration;
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    return '${h.toString().padLeft(2, '0')}:'
        '${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')}';
  }

  @override
  State<AikoFab> createState() => _AikoFabState();
}

class _AikoFabState extends State<AikoFab> {
  Timer? _ticker;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant AikoFab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.running != widget.running ||
        oldWidget.startedAt != widget.startedAt) {
      _syncTicker();
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _syncTicker() {
    _ticker?.cancel();
    _ticker = null;
    _elapsed = _computeElapsed();
    if (widget.running && widget.startedAt != null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _elapsed = _computeElapsed());
      });
    }
  }

  Duration _computeElapsed() {
    final started = widget.startedAt;
    if (!widget.running || started == null) return Duration.zero;
    final delta = DateTime.now().difference(started);
    // A clock adjustment can make this negative; show zero rather than a
    // nonsense countdown.
    return delta.isNegative ? Duration.zero : delta;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fabTheme = theme.floatingActionButtonTheme;

    final Color background =
        fabTheme.backgroundColor ?? scheme.primaryContainer;
    final Color foreground =
        fabTheme.foregroundColor ?? scheme.onPrimaryContainer;

    final TextStyle labelStyle =
        (fabTheme.extendedTextStyle ??
                theme.textTheme.titleSmall ??
                const TextStyle())
            .copyWith(
              color: foreground,
              height: 1,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            );

    final String label = AikoFab.formatElapsed(_elapsed);
    final double labelWidth = _measureLabel(context, label, labelStyle);
    const double trailingPadding = 20;

    final double targetWidth = widget.running
        ? AikoDims.fabSize + labelWidth + trailingPadding
        : AikoDims.fabSize;

    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AikoDims.fabRadius),
    );

    Widget glyph;
    if (widget.busy) {
      glyph = SizedBox(
        key: const ValueKey<String>('busy'),
        width: 22,
        height: 22,
        child: CircularProgressIndicator(strokeWidth: 2.5, color: foreground),
      );
    } else {
      glyph = Icon(
        widget.running ? widget.runningIcon : widget.stoppedIcon,
        key: ValueKey<String>(widget.running ? 'running' : 'stopped'),
        size: 26,
        color: foreground,
      );
    }

    Widget fab = AnimatedContainer(
      duration: AikoDims.slowMotion,
      curve: Curves.easeOutCubic,
      width: targetWidth,
      height: AikoDims.fabSize,
      clipBehavior: Clip.antiAlias,
      decoration: ShapeDecoration(
        color: background,
        shape: shape,
        shadows: theme.brightness == Brightness.light
            ? <BoxShadow>[
                BoxShadow(
                  color: scheme.shadow.withValues(alpha: 0.18),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ]
            : null,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: widget.onPressed,
          customBorder: shape,
          // The pill's content is always laid out at its full running width;
          // the container clips it while collapsed. That is what keeps the
          // glyph pinned in the same place through the whole morph.
          child: OverflowBox(
            alignment: Alignment.centerLeft,
            minWidth: 0,
            maxWidth: double.infinity,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SizedBox(
                  width: AikoDims.fabSize,
                  height: AikoDims.fabSize,
                  child: Center(
                    child: AnimatedSwitcher(
                      duration: AikoDims.midMotion,
                      switchInCurve: Curves.easeOut,
                      switchOutCurve: Curves.easeIn,
                      transitionBuilder: (child, animation) => FadeTransition(
                        opacity: animation,
                        child: ScaleTransition(scale: animation, child: child),
                      ),
                      child: glyph,
                    ),
                  ),
                ),
                SizedBox(
                  width: labelWidth,
                  child: Text(
                    label,
                    style: labelStyle,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.clip,
                  ),
                ),
                const SizedBox(width: trailingPadding),
              ],
            ),
          ),
        ),
      ),
    );

    if (widget.tooltip != null) {
      fab = Tooltip(message: widget.tooltip!, child: fab);
    }

    return Semantics(
      button: true,
      enabled: widget.onPressed != null,
      label: widget.semanticLabel,
      child: fab,
    );
  }

  static double _measureLabel(
    BuildContext context,
    String label,
    TextStyle style,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    return painter.width;
  }
}
