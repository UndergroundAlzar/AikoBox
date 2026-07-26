import 'package:flutter/material.dart';

/// One entry of the user-selectable seed palette.
///
/// [id] is what gets persisted — never persist the ARGB value, because the
/// palette is allowed to be re-tuned between releases without invalidating a
/// user's choice.
///
/// [nameKey] is an `l10n` key, not a display string. The theme page resolves it
/// through `AikoL10n`; the design system itself never renders it.
@immutable
class AikoSeedColor {
  const AikoSeedColor({
    required this.id,
    required this.color,
    required this.nameKey,
  });

  /// Stable persistence key.
  final String id;

  /// The seed handed to `ColorScheme.fromSeed`.
  final Color color;

  /// `l10n` key for the human-readable name.
  final String nameKey;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AikoSeedColor &&
          other.id == id &&
          other.color == color &&
          other.nameKey == nameKey;

  @override
  int get hashCode => Object.hash(id, color, nameKey);

  @override
  String toString() => 'AikoSeedColor($id)';
}

/// [AikoSeedColor.id] used when nothing has been persisted yet.
const String kAikoDefaultSeedColorId = 'crimson';

/// The default seed's ARGB value, exposed separately because `.color` on a
/// const object is not itself a constant expression and this needs to be usable
/// as a default parameter value.
const Color kAikoDefaultSeedColorValue = Color(0xFFC1121F);

/// Aiko's eyes. The product's default accent.
const AikoSeedColor kAikoSeedCrimson = AikoSeedColor(
  id: kAikoDefaultSeedColorId,
  color: kAikoDefaultSeedColorValue,
  nameKey: 'theme.seed.crimson',
);

const AikoSeedColor kAikoSeedSakura = AikoSeedColor(
  id: 'sakura',
  color: Color(0xFFD8A0AE),
  nameKey: 'theme.seed.sakura',
);

const AikoSeedColor kAikoSeedAmber = AikoSeedColor(
  id: 'amber',
  color: Color(0xFFE0952A),
  nameKey: 'theme.seed.amber',
);

const AikoSeedColor kAikoSeedJade = AikoSeedColor(
  id: 'jade',
  color: Color(0xFF2F9E68),
  nameKey: 'theme.seed.jade',
);

const AikoSeedColor kAikoSeedAzure = AikoSeedColor(
  id: 'azure',
  color: Color(0xFF2C7BD4),
  nameKey: 'theme.seed.azure',
);

const AikoSeedColor kAikoSeedIndigo = AikoSeedColor(
  id: 'indigo',
  color: Color(0xFF5A54C6),
  nameKey: 'theme.seed.indigo',
);

const AikoSeedColor kAikoSeedViolet = AikoSeedColor(
  id: 'violet',
  color: Color(0xFF8E56CE),
  nameKey: 'theme.seed.violet',
);

const AikoSeedColor kAikoSeedSlate = AikoSeedColor(
  id: 'slate',
  color: Color(0xFF5A6B7C),
  nameKey: 'theme.seed.slate',
);

/// The palette rendered as swatches on the theme page, in display order.
const List<AikoSeedColor> kAikoSeedColors = <AikoSeedColor>[
  kAikoSeedCrimson,
  kAikoSeedSakura,
  kAikoSeedAmber,
  kAikoSeedJade,
  kAikoSeedAzure,
  kAikoSeedIndigo,
  kAikoSeedViolet,
  kAikoSeedSlate,
];

/// The seed used when nothing has been chosen yet.
const AikoSeedColor kAikoDefaultSeedColor = kAikoSeedCrimson;

/// Resolves a persisted [AikoSeedColor.id] back to a palette entry.
///
/// Unknown or missing ids fall back to [kAikoDefaultSeedColor] rather than
/// throwing: a settings file written by a newer build must never brick the UI.
AikoSeedColor aikoSeedColorById(String? id) {
  if (id == null) return kAikoDefaultSeedColor;
  for (final seed in kAikoSeedColors) {
    if (seed.id == id) return seed;
  }
  return kAikoDefaultSeedColor;
}
