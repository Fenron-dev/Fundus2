import 'package:flutter/widgets.dart';

/// How wide the window is, in the terms a layout actually decides by.
///
/// Three names rather than a pile of numbers: a phone held in one hand, a
/// tablet or a split window, and a full desktop window. Every measurement
/// that changes with the screen is a field on this enum, so no widget has to
/// carry its own breakpoints and drift away from the rest.
enum FundusStageSize {
  handset(
    posterWidth: 116,
    railGap: 10,
    gutter: 16,
    heroRatio: 3 / 4,
    heroMaxHeight: 460,
    titleSize: 26,
  ),
  tablet(
    posterWidth: 150,
    railGap: 14,
    gutter: 24,
    heroRatio: 16 / 10,
    heroMaxHeight: 520,
    titleSize: 34,
  ),
  desktop(
    posterWidth: 178,
    railGap: 16,
    gutter: 32,
    heroRatio: 21 / 9,
    heroMaxHeight: 560,
    titleSize: 40,
  );

  const FundusStageSize({
    required this.posterWidth,
    required this.railGap,
    required this.gutter,
    required this.heroRatio,
    required this.heroMaxHeight,
    required this.titleSize,
  });

  /// The width of one poster in a rail. Grids derive their columns from it.
  final double posterWidth;

  /// The space between two posters.
  final double railGap;

  /// The page margin.
  final double gutter;

  /// The shape of the stage at the top of a screen. A phone gets something
  /// close to a poster, because a 21:9 band on a 360-wide screen is a stripe;
  /// a desktop gets the cinematic one.
  final double heroRatio;

  final double heroMaxHeight;

  /// The size of a work's name on the stage.
  final double titleSize;

  double get posterHeight => posterWidth * 3 / 2;

  static FundusStageSize of(BuildContext context) =>
      forWidth(MediaQuery.sizeOf(context).width);

  static FundusStageSize forWidth(double width) => width < 600
      ? FundusStageSize.handset
      : width < 1100
      ? FundusStageSize.tablet
      : FundusStageSize.desktop;
}

/// The corner a poster is cut to. Larger than the interface's own radius:
/// artwork reads as artwork, not as another panel.
abstract final class FundusArtwork {
  static const posterRadius = BorderRadius.all(Radius.circular(10));
  static const cardRadius = BorderRadius.all(Radius.circular(14));
  static const heroRadius = BorderRadius.all(Radius.circular(18));
}
