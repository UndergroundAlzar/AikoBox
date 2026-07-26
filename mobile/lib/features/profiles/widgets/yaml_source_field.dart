/// A plain-`TextField` YAML editor with a line-number gutter.
///
/// The desktop uses Monaco; there is no `re_editor` (or any other code editor)
/// in `pubspec.yaml` and adding one is out of scope, so this is built from a
/// `TextField`. Two decisions make that workable rather than merely present:
///
///  * **No soft wrap.** The field sits inside a horizontal scroll view sized to
///    the longest line, so one logical line is always one visual row. That is
///    what keeps the gutter aligned; a wrapped editor would need the gutter to
///    know each line's rendered height, which a `TextField` does not expose.
///  * **The long-line width is counted, not measured.** The text is monospaced,
///    so the widest line is the one with the most characters and its width is
///    that count times one advance. Measuring every line with a `TextPainter`
///    on a 10 000-line profile would cost more than the whole frame.
///
/// The field itself is dumb: syntax validity is the save button's problem, and
/// [errorLine] is how the page tells it where the parser stopped.
library;

import 'package:aikobox_mobile/theme/app_theme.dart';
import 'package:flutter/material.dart';

/// Monospace family stack. `monospace` resolves to Droid Sans Mono on Android;
/// the fallbacks keep the editor monospaced under `flutter test` and on desktop
/// hosts, where that family does not exist.
const List<String> kEditorFontFallback = <String>[
  'RobotoMono',
  'Courier New',
  'Courier',
];
const String kEditorFontFamily = 'monospace';

class YamlSourceField extends StatefulWidget {
  const YamlSourceField({
    super.key,
    required this.controller,
    this.readOnly = false,
    this.errorLine,
    this.fontSize = 13,
    this.showLineNumbers = true,
    this.scrollController,
  });

  final TextEditingController controller;
  final bool readOnly;

  /// 1-based line to highlight in the gutter, from the last failed save.
  final int? errorLine;

  final double fontSize;
  final bool showLineNumbers;

  /// Vertical scroll controller, so a page can scroll the error into view.
  final ScrollController? scrollController;

  @override
  State<YamlSourceField> createState() => _YamlSourceFieldState();
}

class _YamlSourceFieldState extends State<YamlSourceField> {
  late final ScrollController _vertical =
      widget.scrollController ?? ScrollController();
  final ScrollController _horizontal = ScrollController();
  bool _ownsVertical = false;

  int _lineCount = 1;
  int _widestLine = 0;

  @override
  void initState() {
    super.initState();
    _ownsVertical = widget.scrollController == null;
    widget.controller.addListener(_onTextChanged);
    _measure(widget.controller.text);
  }

  @override
  void didUpdateWidget(YamlSourceField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onTextChanged);
      widget.controller.addListener(_onTextChanged);
      _measure(widget.controller.text);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    if (_ownsVertical) _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final before = <int>[_lineCount, _widestLine];
    _measure(widget.controller.text);
    if (before[0] != _lineCount || before[1] != _widestLine) {
      if (mounted) setState(() {});
    }
  }

  void _measure(String text) {
    var lines = 1;
    var widest = 0;
    var current = 0;
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 0x0A) {
        lines++;
        if (current > widest) widest = current;
        current = 0;
      } else {
        current++;
      }
    }
    if (current > widest) widest = current;
    _lineCount = lines;
    _widestLine = widest;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final TextStyle codeStyle = TextStyle(
      fontFamily: kEditorFontFamily,
      fontFamilyFallback: kEditorFontFallback,
      fontSize: widget.fontSize,
      height: 1.45,
      color: scheme.onSurface,
    );
    final double lineHeight = widget.fontSize * 1.45;
    final double advance = widget.fontSize * 0.62;
    final double gutterWidth = widget.showLineNumbers
        ? 18 + '$_lineCount'.length * (widget.fontSize * 0.66)
        : 0;

    return DecoratedBox(
      decoration: ShapeDecoration(
        color: scheme.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AikoDims.cardRadius),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AikoDims.cardRadius),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // +2 columns of slack so the caret at the end of the widest line is
            // not clipped by the scroll extent.
            final double textWidth = (_widestLine + 2) * advance;
            final double available = constraints.maxWidth - gutterWidth - 24;
            final double contentWidth = textWidth > available
                ? textWidth
                : available.clamp(1.0, double.infinity);

            return Scrollbar(
              controller: _vertical,
              child: SingleChildScrollView(
                controller: _vertical,
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    if (widget.showLineNumbers)
                      _Gutter(
                        lineCount: _lineCount,
                        lineHeight: lineHeight,
                        width: gutterWidth,
                        errorLine: widget.errorLine,
                        style: codeStyle,
                      ),
                    Expanded(
                      child: SingleChildScrollView(
                        controller: _horizontal,
                        scrollDirection: Axis.horizontal,
                        child: SizedBox(
                          width: contentWidth,
                          child: TextField(
                            controller: widget.controller,
                            readOnly: widget.readOnly,
                            maxLines: null,
                            expands: false,
                            style: codeStyle,
                            strutStyle: StrutStyle(
                              fontFamily: kEditorFontFamily,
                              fontFamilyFallback: kEditorFontFallback,
                              fontSize: widget.fontSize,
                              height: 1.45,
                              forceStrutHeight: true,
                            ),
                            cursorColor: scheme.primary,
                            keyboardType: TextInputType.multiline,
                            textInputAction: TextInputAction.newline,
                            // Autocorrect turning `dns:` into `DNS:` would be a
                            // very annoying way to break a config.
                            autocorrect: false,
                            enableSuggestions: false,
                            smartDashesType: SmartDashesType.disabled,
                            smartQuotesType: SmartQuotesType.disabled,
                            scrollPhysics:
                                const NeverScrollableScrollPhysics(),
                            decoration: const InputDecoration(
                              isDense: true,
                              border: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _Gutter extends StatelessWidget {
  const _Gutter({
    required this.lineCount,
    required this.lineHeight,
    required this.width,
    required this.errorLine,
    required this.style,
  });

  final int lineCount;
  final double lineHeight;
  final double width;
  final int? errorLine;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (var line = 1; line <= lineCount; line++)
            SizedBox(
              height: lineHeight,
              child: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 10),
                color: line == errorLine
                    ? scheme.errorContainer
                    : Colors.transparent,
                child: Text(
                  '$line',
                  textAlign: TextAlign.right,
                  style: style.copyWith(
                    color: line == errorLine
                        ? scheme.onErrorContainer
                        : scheme.onSurfaceVariant.withValues(alpha: 0.6),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
