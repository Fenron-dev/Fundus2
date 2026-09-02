import 'package:flutter/material.dart';

/// The app type scale. Nocturne's marketing scale stopped at display sizes;
/// these are the seven sizes the interface actually uses.
///
/// Hierarchy here is size and space — headings never go past weight 500.
abstract final class FundusType {
  static const fontFamily = 'Inter';
  static const fallback = <String>['Inter', 'Roboto', 'Helvetica', 'Arial'];

  /// Badges and kickers.
  static const xs = 11.0;

  /// Metadata, list rows.
  static const sm = 12.5;

  /// Standard interface text.
  static const base = 14.0;

  /// Emphasised body text.
  static const md = 16.0;

  /// Card titles, chapter names.
  static const lg = 20.0;

  /// Screen titles.
  static const xl = 25.0;

  /// Work titles on a detail screen.
  static const xxl = 32.0;

  static const headingWeight = FontWeight.w500;
  static const bodyWeight = FontWeight.w400;

  /// Kickers are uppercase with wide tracking — the one place where letter
  /// spacing is deliberate rather than inherited.
  static const kickerSpacing = 1.3;

  static TextStyle _style(double size, FontWeight weight, Color color) =>
      TextStyle(
        fontFamily: fontFamily,
        fontFamilyFallback: fallback,
        fontSize: size,
        fontWeight: weight,
        color: color,
        height: 1.35,
      );

  static TextTheme textTheme({required Color text, required Color muted}) =>
      TextTheme(
        displayLarge: _style(xxl, headingWeight, text),
        displayMedium: _style(xl, headingWeight, text),
        headlineLarge: _style(xl, headingWeight, text),
        headlineMedium: _style(lg, headingWeight, text),
        headlineSmall: _style(md, headingWeight, text),
        titleLarge: _style(lg, headingWeight, text),
        titleMedium: _style(md, headingWeight, text),
        titleSmall: _style(base, headingWeight, text),
        bodyLarge: _style(md, bodyWeight, text),
        bodyMedium: _style(base, bodyWeight, text),
        bodySmall: _style(sm, bodyWeight, muted),
        labelLarge: _style(base, headingWeight, text),
        labelMedium: _style(sm, bodyWeight, muted),
        labelSmall: _style(
          xs,
          headingWeight,
          muted,
        ).copyWith(letterSpacing: kickerSpacing),
      );
}
