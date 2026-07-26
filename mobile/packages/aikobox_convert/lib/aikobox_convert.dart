/// Pure-Dart Clash (mihomo) YAML to sing-box JSON converter, spec-locked
/// against the AikoBox desktop implementation.
///
/// ```dart
/// final result = convertClashToSingbox(
///   clashConfigMap,
///   options: const ConvertOptions(platform: 'android', autoRedirect: false),
/// );
/// if (result.errors.isNotEmpty) {
///   // DO NOT START THE CORE. Every error means the emitted config would have
///   // routed traffic somewhere the profile did not ask for.
/// }
/// ```
///
/// The internals are available through
/// `package:aikobox_convert/internals.dart` for tests and for anything that
/// needs the coercion primitives; they are deliberately kept out of this
/// barrel so the top-level names cannot collide with an app's own helpers.
library;

export 'src/convert.dart' show convertClashToSingbox, deriveController;
export 'src/models.dart' show ConvertOptions, ConvertResult, SingboxController;
export 'src/safe_regex.dart' show ClashRegexException, compileSafeClashRegex;
