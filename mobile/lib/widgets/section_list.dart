import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// One row of a [SectionList].
///
/// [title] and [subtitle] are already-localised display strings.
@immutable
class SectionListTile {
  const SectionListTile({
    required this.title,
    this.subtitle,
    this.icon,
    this.leading,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.enabled = true,
    this.destructive = false,
    this.itemKey,
  });

  final String title;
  final String? subtitle;

  /// Leading icon. Ignored when [leading] is supplied.
  final IconData? icon;

  /// Custom leading widget (an avatar, a coloured dot, …).
  final Widget? leading;

  final Widget? trailing;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  final bool enabled;

  /// Renders the row in `colorScheme.error` — "delete profile", "reset".
  final bool destructive;

  /// Key applied to the built `ListTile`, for tests and scroll targeting.
  final Key? itemKey;

  bool get hasLeading => leading != null || icon != null;
}

/// A group of rows under an optional header.
@immutable
class SectionListSection {
  const SectionListSection({this.title, required this.tiles});

  /// Already-localised header text. Null renders the group with no header.
  final String? title;

  final List<SectionListTile> tiles;
}

/// The Tools page list: sections of `ListTile`s under primary-tinted headers,
/// separated by thin dividers that align to the text column.
class SectionList extends StatelessWidget {
  const SectionList({
    super.key,
    required this.sections,
    this.padding,
    this.controller,
    this.shrinkWrap = false,
    this.physics,
    this.showDividers = true,
  });

  final List<SectionListSection> sections;

  final EdgeInsetsGeometry? padding;
  final ScrollController? controller;
  final bool shrinkWrap;
  final ScrollPhysics? physics;

  /// Hairlines between rows inside a section. Headers never get one.
  final bool showDividers;

  @override
  Widget build(BuildContext context) {
    final entries = _flatten();
    return ListView.builder(
      controller: controller,
      shrinkWrap: shrinkWrap,
      physics: physics,
      padding:
          padding ?? const EdgeInsets.only(bottom: AikoDims.fabClearance),
      itemCount: entries.length,
      itemBuilder: (context, index) => entries[index].build(context),
    );
  }

  List<_Entry> _flatten() {
    final entries = <_Entry>[];
    var isFirstHeader = true;
    for (final section in sections) {
      if (section.tiles.isEmpty) continue;
      if (section.title != null) {
        entries.add(_HeaderEntry(section.title!, isFirst: isFirstHeader));
        isFirstHeader = false;
      }
      for (var i = 0; i < section.tiles.length; i++) {
        final tile = section.tiles[i];
        entries.add(_TileEntry(tile));
        final bool isLastInSection = i == section.tiles.length - 1;
        if (showDividers && !isLastInSection) {
          entries.add(_DividerEntry(indented: tile.hasLeading));
        }
      }
    }
    return entries;
  }
}

/// The primary-tinted section header, exposed for pages that need one outside a
/// [SectionList].
class SectionListHeader extends StatelessWidget {
  const SectionListHeader({super.key, required this.title, this.isFirst = false});

  final String title;
  final bool isFirst;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AikoDims.pagePadding,
        isFirst ? 12 : 24,
        AikoDims.pagePadding,
        8,
      ),
      child: Text(
        title,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

abstract class _Entry {
  const _Entry();
  Widget build(BuildContext context);
}

class _HeaderEntry extends _Entry {
  const _HeaderEntry(this.title, {required this.isFirst});
  final String title;
  final bool isFirst;

  @override
  Widget build(BuildContext context) =>
      SectionListHeader(title: title, isFirst: isFirst);
}

class _DividerEntry extends _Entry {
  const _DividerEntry({required this.indented});
  final bool indented;

  @override
  Widget build(BuildContext context) => Divider(
    height: 1,
    thickness: 1,
    // Align the rule with the text column when there is a leading icon, with
    // the page margin otherwise.
    indent: indented ? 56 : AikoDims.pagePadding,
    endIndent: AikoDims.pagePadding,
  );
}

class _TileEntry extends _Entry {
  const _TileEntry(this.tile);
  final SectionListTile tile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final Color? accent = tile.destructive ? scheme.error : null;

    // The theme sets explicit title/subtitle styles, and those win over
    // ListTile.textColor — so a destructive row has to override the styles
    // themselves, not just the colour.
    final TextStyle? titleStyle = accent == null
        ? null
        : (theme.listTileTheme.titleTextStyle ?? theme.textTheme.bodyLarge)
              ?.copyWith(color: accent);
    final TextStyle? subtitleStyle = accent == null
        ? null
        : (theme.listTileTheme.subtitleTextStyle ?? theme.textTheme.bodySmall)
              ?.copyWith(color: accent.withValues(alpha: 0.8));

    return ListTile(
      titleTextStyle: titleStyle,
      subtitleTextStyle: subtitleStyle,
      key: tile.itemKey,
      enabled: tile.enabled,
      leading:
          tile.leading ??
          (tile.icon != null ? Icon(tile.icon, size: 22) : null),
      title: Text(
        tile.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: tile.subtitle != null
          ? Text(
              tile.subtitle!,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            )
          : null,
      trailing: tile.trailing,
      onTap: tile.enabled ? tile.onTap : null,
      onLongPress: tile.enabled ? tile.onLongPress : null,
      iconColor: accent,
      textColor: accent,
    );
  }
}
