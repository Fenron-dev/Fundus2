import 'package:flutter/widgets.dart';

/// The spacing scale, already at Nocturne's 0.70× density. Use the named
/// steps, never a raw number — the density is baked in here so that changing
/// it stays a one-line change.
abstract final class FundusSpace {
  static const x1 = 2.8;
  static const x2 = 5.6;
  static const x3 = 8.4;
  static const x4 = 11.2;
  static const x6 = 16.8;
  static const x8 = 22.4;

  /// Panel padding — added for the app, the marketing tokens stopped at x8.
  static const x10 = 28.0;
  static const x12 = 33.6;

  /// Page gutter.
  static const x16 = 44.8;
}

abstract final class FundusRadius {
  /// Chips and small marks.
  static const sm = Radius.circular(4);

  /// Tiles, fields, buttons.
  static const md = Radius.circular(8);

  /// Panels, dialogs, sheets.
  static const lg = Radius.circular(14);

  static const smAll = BorderRadius.all(sm);
  static const mdAll = BorderRadius.all(md);
  static const lgAll = BorderRadius.all(lg);
}

/// The two densities the design asks for. Everything that changes between
/// "komfortabel" and "kompakt" is a field here, so no widget has to branch on
/// the mode itself.
enum FundusDensity {
  comfortable(
    tilePadding: 12,
    tileMinWidth: 172,
    rowHeight: 64,
    panelPadding: 20,
    gap: 14,
    coverIconSize: 34,
  ),
  compact(
    tilePadding: 7,
    tileMinWidth: 134,
    rowHeight: 42,
    panelPadding: 13,
    gap: 8,
    coverIconSize: 24,
  );

  const FundusDensity({
    required this.tilePadding,
    required this.tileMinWidth,
    required this.rowHeight,
    required this.panelPadding,
    required this.gap,
    required this.coverIconSize,
  });

  final double tilePadding;
  final double tileMinWidth;
  final double rowHeight;
  final double panelPadding;
  final double gap;
  final double coverIconSize;

  FundusDensity get toggled =>
      this == FundusDensity.comfortable ? compact : comfortable;

  String get label => switch (this) {
    FundusDensity.comfortable => 'Komfortabel',
    FundusDensity.compact => 'Kompakt',
  };
}

/// Shell measurements taken from the prototype. The navigation has exactly two
/// states — full and collapsed — and the collapsed one is the same navigation,
/// not a second design.
abstract final class FundusShellMetrics {
  static const navigationWidth = 250.0;
  static const navigationCollapsedWidth = 54.0;
  static const headerHeight = 56.0;
  static const miniPlayerHeight = 68.0;

  /// Below this width the shell drops the navigation column and uses the
  /// mobile layout with a bottom bar.
  static const compactBreakpoint = 900.0;
}
