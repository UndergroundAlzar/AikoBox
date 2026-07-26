import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Verdict on a latency measurement.
enum DelayLevel {
  /// Never measured.
  unknown,

  /// Under [kAikoGoodDelayCeiling] ms.
  good,

  /// At or over [kAikoGoodDelayCeiling] ms.
  warn,

  /// The probe failed or timed out.
  bad,
}

/// Classifies a delay reading.
///
/// The Clash API reports a failed probe as `0` (and some cores as a negative
/// number), which is why anything non-positive is [DelayLevel.bad] rather than
/// an impossibly good result. Thresholds ported from FlClash's `getDelayColor`.
DelayLevel delayLevelFor(int? delay) {
  if (delay == null) return DelayLevel.unknown;
  if (delay <= 0) return DelayLevel.bad;
  if (delay < kAikoGoodDelayCeiling) return DelayLevel.good;
  return DelayLevel.warn;
}

/// The latency pill: green under 600 ms, amber slower, red on failure.
///
/// Failure and "not measured" are drawn as glyphs, not words, so the pill needs
/// no localised string. [unitLabel] defaults to the SI symbol `ms`, which is
/// written the same way in all five shipped locales; pass your own if a locale
/// ever disagrees.
class DelayChip extends StatelessWidget {
  const DelayChip({
    super.key,
    this.delay,
    this.testing = false,
    this.dense = false,
    this.onTap,
    this.unitLabel = 'ms',
    this.tooltip,
  });

  /// Milliseconds. `null` means never measured; `<= 0` means the probe failed.
  final int? delay;

  /// A measurement is in flight — shows a spinner instead of a value.
  final bool testing;

  /// Tighter padding, for proxy grid cells.
  final bool dense;

  final VoidCallback? onTap;

  /// Unit shown after the number.
  final String unitLabel;

  /// Already-localised tooltip, e.g. "tap to re-test".
  final String? tooltip;

  /// Foreground colour for a delay reading, for callers that render the value
  /// themselves instead of using the pill.
  static Color foregroundFor(BuildContext context, int? delay) {
    final colors = AikoStatusColors.of(context);
    return switch (delayLevelFor(delay)) {
      DelayLevel.good => colors.good,
      DelayLevel.warn => colors.warn,
      DelayLevel.bad => colors.bad,
      DelayLevel.unknown => colors.onNeutralContainer,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AikoStatusColors.of(context);
    final level = delayLevelFor(delay);

    final (Color background, Color foreground) = switch (level) {
      DelayLevel.good => (colors.goodContainer, colors.onGoodContainer),
      DelayLevel.warn => (colors.warnContainer, colors.onWarnContainer),
      DelayLevel.bad => (colors.badContainer, colors.onBadContainer),
      DelayLevel.unknown => (
        colors.neutralContainer,
        colors.onNeutralContainer,
      ),
    };

    final double glyphSize = dense ? 11 : 12;
    final textStyle = (theme.textTheme.labelSmall ?? const TextStyle()).copyWith(
      color: foreground,
      height: 1.1,
      fontSize: dense ? 11 : null,
    );

    final Widget content;
    if (testing) {
      content = SizedBox(
        width: glyphSize,
        height: glyphSize,
        child: CircularProgressIndicator(strokeWidth: 2, color: foreground),
      );
    } else {
      content = switch (level) {
        DelayLevel.unknown => Text('—', style: textStyle),
        DelayLevel.bad => Icon(
          Icons.close_rounded,
          size: glyphSize + 2,
          color: foreground,
        ),
        DelayLevel.good ||
        DelayLevel.warn => Text('$delay $unitLabel', style: textStyle),
      };
    }

    Widget pill = AnimatedContainer(
      duration: AikoDims.fastMotion,
      curve: Curves.easeOut,
      constraints: BoxConstraints(minHeight: dense ? 18 : 22, minWidth: 28),
      alignment: Alignment.center,
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 6 : 8,
        vertical: dense ? 1 : 3,
      ),
      decoration: ShapeDecoration(color: background, shape: const StadiumBorder()),
      child: content,
    );

    if (onTap != null) {
      pill = Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          customBorder: const StadiumBorder(),
          child: pill,
        ),
      );
    }

    if (tooltip != null) {
      pill = Tooltip(message: tooltip!, child: pill);
    }

    return pill;
  }
}
