import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// One line of a [Sparkline].
@immutable
class SparklineSeries {
  const SparklineSeries({
    required this.values,
    this.color,
    this.fill = true,
    this.strokeWidth = 2,
  });

  /// Oldest sample first. Negative values are clamped to zero.
  final List<double> values;

  /// Line colour. Falls back to `colorScheme.primary`.
  final Color? color;

  /// Paint a vertical gradient under the line.
  final bool fill;

  final double strokeWidth;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SparklineSeries &&
          listEquals(other.values, values) &&
          other.color == color &&
          other.fill == fill &&
          other.strokeWidth == strokeWidth;

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(values), color, fill, strokeWidth);
}

/// A smoothed line chart with no chart library behind it.
///
/// Built for the dashboard traffic card: one or two rolling windows of samples,
/// repainted several times a second. The path is smoothed with quadratic
/// béziers through segment midpoints (FlClash's `LineChart` does the same), and
/// value changes are tweened so a shifting window slides rather than jumps.
///
/// All series share one vertical scale so up and down are directly comparable.
class Sparkline extends StatefulWidget {
  const Sparkline({
    super.key,
    required this.series,
    this.maxValue,
    this.animate = true,
    this.duration = AikoDims.slowMotion,
  });

  /// Single-series convenience constructor.
  Sparkline.single({
    Key? key,
    required List<double> values,
    Color? color,
    bool fill = true,
    double strokeWidth = 2,
    double? maxValue,
    bool animate = true,
    Duration duration = AikoDims.slowMotion,
  }) : this(
         key: key,
         series: <SparklineSeries>[
           SparklineSeries(
             values: values,
             color: color,
             fill: fill,
             strokeWidth: strokeWidth,
           ),
         ],
         maxValue: maxValue,
         animate: animate,
         duration: duration,
       );

  final List<SparklineSeries> series;

  /// Fixes the top of the vertical scale. When null the scale is the largest
  /// sample across every series, so the chart always uses its full height.
  final double? maxValue;

  final bool animate;
  final Duration duration;

  @override
  State<Sparkline> createState() => _SparklineState();
}

class _SparklineState extends State<Sparkline>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );

  late List<List<double>> _from;
  late List<List<double>> _to;

  @override
  void initState() {
    super.initState();
    _to = _snapshotOf(widget.series);
    _from = _to;
    _controller.value = 1;
  }

  @override
  void didUpdateWidget(covariant Sparkline oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.duration = widget.duration;

    final next = _snapshotOf(widget.series);
    if (_sameShape(next, _to) && _sameValues(next, _to)) return;

    if (!widget.animate || !_sameShape(next, _to)) {
      // A different series count or sample count has no meaningful
      // interpolation; snap instead of drawing a nonsense in-between frame.
      _from = next;
      _to = next;
      _controller.value = 1;
      setState(() {});
      return;
    }

    _from = _interpolate(_controller.value);
    _to = next;
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  static List<List<double>> _snapshotOf(List<SparklineSeries> series) => series
      .map((s) => List<double>.unmodifiable(s.values))
      .toList(growable: false);

  static bool _sameShape(List<List<double>> a, List<List<double>> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].length != b[i].length) return false;
    }
    return true;
  }

  static bool _sameValues(List<List<double>> a, List<List<double>> b) {
    for (var i = 0; i < a.length; i++) {
      if (!listEquals(a[i], b[i])) return false;
    }
    return true;
  }

  List<List<double>> _interpolate(double t) {
    if (t >= 1) return _to;
    if (t <= 0) return _from;
    return <List<double>>[
      for (var i = 0; i < _to.length; i++)
        <double>[
          for (var j = 0; j < _to[i].length; j++)
            _from[i][j] + (_to[i][j] - _from[i][j]) * t,
        ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = <Color>[
      for (final s in widget.series) s.color ?? scheme.primary,
    ];
    final fills = <bool>[for (final s in widget.series) s.fill];
    final strokes = <double>[for (final s in widget.series) s.strokeWidth];

    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return CustomPaint(
            size: Size.infinite,
            painter: _SparklinePainter(
              seriesValues: _interpolate(_controller.value),
              colors: colors,
              fills: fills,
              strokeWidths: strokes,
              maxValue: widget.maxValue,
            ),
          );
        },
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({
    required this.seriesValues,
    required this.colors,
    required this.fills,
    required this.strokeWidths,
    required this.maxValue,
  });

  final List<List<double>> seriesValues;
  final List<Color> colors;
  final List<bool> fills;
  final List<double> strokeWidths;
  final double? maxValue;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final double scaleMax = _scaleMax();
    if (scaleMax <= 0) return;

    for (var i = 0; i < seriesValues.length; i++) {
      final values = seriesValues[i];
      if (values.length < 2) continue;

      final stroke = strokeWidths[i];
      final points = _pointsFor(values, size, scaleMax, stroke);
      final linePath = _smoothPath(points);

      if (fills[i]) {
        final fillPath = Path.from(linePath)
          ..lineTo(points.last.dx, size.height)
          ..lineTo(points.first.dx, size.height)
          ..close();
        canvas.drawPath(
          fillPath,
          Paint()
            ..style = PaintingStyle.fill
            ..shader = ui.Gradient.linear(
              Offset(0, 0),
              Offset(0, size.height),
              <Color>[
                colors[i].withValues(alpha: 0.26),
                colors[i].withValues(alpha: 0.0),
              ],
            ),
        );
      }

      canvas.drawPath(
        linePath,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = colors[i],
      );
    }
  }

  double _scaleMax() {
    if (maxValue != null) return maxValue!;
    var found = 0.0;
    for (final values in seriesValues) {
      for (final v in values) {
        if (v > found) found = v;
      }
    }
    // A flat-zero window would divide by zero; give it a nominal scale so the
    // line sits on the baseline instead of vanishing.
    return found > 0 ? found : 1;
  }

  List<Offset> _pointsFor(
    List<double> values,
    Size size,
    double scaleMax,
    double stroke,
  ) {
    final dx = size.width / (values.length - 1);
    final baseline = size.height - stroke / 2;
    final usable = math.max(0.0, size.height - stroke * 1.5);
    return <Offset>[
      for (var i = 0; i < values.length; i++)
        Offset(
          i * dx,
          baseline - (values[i].clamp(0.0, scaleMax) / scaleMax) * usable,
        ),
    ];
  }

  /// Quadratic béziers through segment midpoints — cheap smoothing that cannot
  /// overshoot the data the way a cubic spline can.
  Path _smoothPath(List<Offset> points) {
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length; i++) {
      final prev = points[i - 1];
      final cur = points[i];
      final mid = Offset((prev.dx + cur.dx) / 2, (prev.dy + cur.dy) / 2);
      path.quadraticBezierTo(prev.dx, prev.dy, mid.dx, mid.dy);
    }
    path.lineTo(points.last.dx, points.last.dy);
    return path;
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) {
    if (old.maxValue != maxValue) return true;
    if (!listEquals(old.colors, colors)) return true;
    if (!listEquals(old.fills, fills)) return true;
    if (!listEquals(old.strokeWidths, strokeWidths)) return true;
    if (old.seriesValues.length != seriesValues.length) return true;
    for (var i = 0; i < seriesValues.length; i++) {
      if (!listEquals(old.seriesValues[i], seriesValues[i])) return true;
    }
    return false;
  }
}
