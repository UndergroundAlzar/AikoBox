/// The converter's internals: the coercion primitives and the per-section
/// builders.
///
/// Exported as a second entry point rather than from
/// `package:aikobox_convert/aikobox_convert.dart` because names like [toStr],
/// [toNum] and [compact] are generic enough to collide with an application's
/// own helpers. Import this from tests, or from code that genuinely needs to
/// reproduce the converter's coercion rules.
library;

export 'src/convert.dart';
export 'src/dns.dart';
export 'src/groups.dart';
export 'src/inbounds.dart';
export 'src/models.dart';
export 'src/outbounds.dart';
export 'src/primitives.dart';
export 'src/rules.dart';
export 'src/safe_regex.dart';
